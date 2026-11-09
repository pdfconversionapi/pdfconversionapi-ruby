# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "timeout"
require "uri"

module PdfConversionApi
  # The API client. Safe to share between threads: it keeps no per-request state.
  #
  #   client = PdfConversionApi::Client.new          # reads PDFCONVERSIONAPI_KEY
  #   result = client.convert_file("report.docx", "pdf")
  #   result.save_all("out")                           # writes out/report.pdf
  class Client
    DEFAULT_BASE_URL = "https://api.pdfconversionapi.com"
    DEFAULT_TIMEOUT = 240
    DEFAULT_CONNECT_TIMEOUT = 10
    DEFAULT_MAX_RETRIES = 4
    DEFAULT_MAX_RETRY_WAIT = 60

    USER_AGENT = "pdfconversionapi-ruby/#{VERSION} ruby/#{RUBY_VERSION}".freeze

    FORMAT = /\A[A-Za-z0-9-]{1,20}\z/.freeze
    FILE_ID = /\A[0-9A-Fa-f]{32}\z/.freeze

    # Raised inside an attempt when the whole-response deadline passes.
    class Deadline < StandardError; end
    private_constant :Deadline

    # Wraps a transport error raised after the status line arrived (SPEC 8, rule 3a).
    class BodyFailure < StandardError; end
    private_constant :BodyFailure

    # An HTTP response, body read.
    Response = Struct.new(:status, :headers, :body) do
      def request_id
        value = headers["x-request-id"]
        value.nil? || value.empty? ? nil : value
      end
    end
    private_constant :Response

    # Transport failures. Before a status line arrives they mean "no response" and are retried
    # with backoff (a connect timeout included); after it, they are raised at once.
    CONNECTION_FAILURES = (
      [Net::OpenTimeout, SocketError, IOError, Net::HTTPBadResponse, OpenSSL::SSL::SSLError] +
      %i[ECONNREFUSED ECONNRESET ECONNABORTED EPIPE ETIMEDOUT EHOSTUNREACH ENETUNREACH ENETDOWN EHOSTDOWN
         EADDRNOTAVAIL].filter_map { |name| Errno.const_get(name) if Errno.const_defined?(name) }
    ).freeze
    private_constant :CONNECTION_FAILURES

    # Failures while reading a body: the transport ones, plus a compressed body cut short.
    BODY_FAILURES = (CONNECTION_FAILURES + (defined?(Zlib::Error) ? [Zlib::Error] : [])).freeze
    private_constant :BODY_FAILURES

    # @return [String] the base URL, without a trailing slash
    attr_reader :base_url
    # @return [Numeric] seconds per attempt for the whole response
    attr_reader :timeout
    # @return [Numeric] seconds to open the connection
    attr_reader :connect_timeout
    # @return [Integer] retries after the first attempt
    attr_reader :max_retries
    # @return [Numeric] the longest Retry-After waited for, in seconds
    attr_reader :max_retry_wait

    # @param api_key [String, nil] the API key; defaults to the PDFCONVERSIONAPI_KEY environment
    #   variable. May be missing: #conversions and downloads work without one.
    # @param base_url [String, nil] defaults to PDFCONVERSIONAPI_BASE_URL, else
    #   https://api.pdfconversionapi.com
    # @param timeout [Numeric] seconds per attempt for the whole response (240)
    # @param connect_timeout [Numeric] seconds to open the connection (10)
    # @param max_retries [Integer] retries after the first attempt (4); 0 turns retries off
    # @param max_retry_wait [Numeric] a Retry-After longer than this many seconds (60) is not
    #   waited for: the error is raised at once
    # @param sleeper [#call, nil] for tests: called with the seconds to wait between attempts
    #   instead of Kernel#sleep
    def initialize(api_key: nil, base_url: nil, timeout: DEFAULT_TIMEOUT, connect_timeout: DEFAULT_CONNECT_TIMEOUT,
                   max_retries: DEFAULT_MAX_RETRIES, max_retry_wait: DEFAULT_MAX_RETRY_WAIT, sleeper: nil)
      @api_key = normalize_key(api_key.nil? ? ENV.fetch("PDFCONVERSIONAPI_KEY", nil) : api_key)
      @base_url = normalize_base_url(base_url)
      @timeout = positive_number(timeout, "timeout")
      @connect_timeout = positive_number(connect_timeout, "connect_timeout")
      unless max_retries.is_a?(Integer) && max_retries >= 0
        raise ArgumentError, "max_retries must be an Integer of 0 or more, got #{max_retries.inspect}"
      end

      @max_retries = max_retries
      unless max_retry_wait.is_a?(Numeric) && max_retry_wait >= 0
        raise ArgumentError, "max_retry_wait must be a number of 0 or more, got #{max_retry_wait.inspect}"
      end

      @max_retry_wait = max_retry_wait
      raise ArgumentError, "sleeper must respond to #call" unless sleeper.nil? || sleeper.respond_to?(:call)

      @sleeper = sleeper || Kernel.method(:sleep)
      freeze
    end

    # Whether the client has an API key.
    def api_key?
      !@api_key.nil?
    end

    def inspect
      "#<#{self.class.name} base_url=#{@base_url.inspect} api_key=#{api_key? ? '[set]' : '[none]'} " \
        "timeout=#{@timeout} max_retries=#{@max_retries}>"
    end
    alias to_s inspect

    # Converts files: POST /v2/convert/{from}/to/{to}.
    #
    #   client.convert("pdf", "jpg", "guide.pdf", params: { ImageResolution: 72 })
    #   client.convert("pdf", "merge", ["a.pdf", "b.pdf"], file_name: "both")
    #   client.convert("data", "qrcode", params: { Data: "https://example.com" })
    #
    # @param from [String] the input format (1-20 letters, digits or hyphens, any case)
    # @param to [String] the output format, or a tool such as "merge" or "compress"
    # @param files [String, Pathname, IO, UploadFile, Array, nil] one input or a list. A String is
    #   a path. One file is sent as File, two or more as repeated Files fields. Without files
    #   (nil or []) the request has no file field: a few conversions, such as data/to/qrcode,
    #   take none, and the others answer 400 "no input file was provided".
    # @param params [Hash, nil] parameter name => value. Strings, numbers, booleans and Symbols are
    #   sent as text, nil is left out, and an UploadFile, Pathname or IO is sent as a file field
    #   with that name (such as ImageFile). A String value is text here, never a path.
    # @param file_name [String, nil] the output's name, without extension (sent as FileName)
    # @param store_file [Boolean, nil] true stores the outputs and returns links (StoreFile=true)
    # @param timeout [Numeric, nil] seconds for this call, instead of the client's timeout
    # @return [ConversionResult]
    def convert(from, to, files = nil, params: nil, file_name: nil, store_file: nil, timeout: nil)
      from = format_name(from, "from")
      to = format_name(to, "to")
      inputs = if files.nil? then []
               elsif files.is_a?(Array) then files
               else [files]
               end

      params = check_params(params)
      raise ArgumentError, "file_name must be a String" unless file_name.nil? || file_name.is_a?(String)
      unless [nil, true, false].include?(store_file)
        raise ArgumentError, "store_file must be true, false or nil, got #{store_file.inspect}"
      end

      call_timeout = timeout.nil? ? @timeout : positive_number(timeout, "timeout")
      key = require_key
      form = build_form(inputs.map { |input| UploadFile.coerce(input) }, params, file_name, store_file)
      response = execute(:post, "#{@base_url}/v2/convert/#{from}/to/#{to}", key: key, form: form,
                                                                          timeout: call_timeout)
      raise_error(response) unless response.status == 200
      ConversionResult.parse(parse_json(response), response.request_id, self)
    end

    # Converts one file from a path, reading the input format from its extension.
    #
    #   client.convert_file("report.docx", "pdf").save_all("out")
    #
    # @param path [String, Pathname]
    # @param to [String] the output format or tool
    # @return [ConversionResult]
    # @see #convert for params, file_name, store_file and timeout
    def convert_file(path, to, params: nil, file_name: nil, store_file: nil, timeout: nil)
      path = UploadFile.path_string(path)
      ext = File.extname(path).delete_prefix(".")
      if ext.empty?
        raise ArgumentError,
              "can't tell the format of #{File.basename(path).inspect}: it has no extension; " \
              "use convert(from, to, file)"
      end

      convert(ext.downcase, to, UploadFile.from_path(path), params: params, file_name: file_name, store_file: store_file,
                                        timeout: timeout)
    end

    # Your plan, its limits and this month's count: GET /v2/usage.
    #
    # @return [Usage]
    def usage
      response = execute(:get, "#{@base_url}/v2/usage", key: require_key)
      raise_error(response) unless response.status == 200
      Usage.parse(parse_json(response), response.request_id)
    end

    # Every conversion the API offers: GET /v2/info. Needs no key.
    #
    # @return [Array<Conversion>]
    def conversions
      response = execute(:get, "#{@base_url}/v2/info")
      raise_error(response) unless response.status == 200
      Conversion.parse(parse_json(response), response.request_id)
    end

    # Downloads a stored file from its Url, as returned by the API. No API key is sent.
    #
    # @param url [String]
    # @param timeout [Numeric, nil] seconds for this call, instead of the client's timeout
    # @return [String] the bytes (binary)
    def download(url, timeout: nil)
      url = download_url(url)
      response = execute(:get, url, json: false, timeout: timeout.nil? ? @timeout : positive_number(timeout, "timeout"))
      raise_error(response) unless response.status == 200
      response.body
    end

    # Downloads a stored file from its Url straight to disk, without holding it in memory. No API
    # key is sent. The file appears at +path+ only once it is complete; an existing file is
    # overwritten.
    #
    # @param url [String]
    # @param path [String, Pathname]
    # @param timeout [Numeric, nil] seconds for this call, instead of the client's timeout
    # @return [String] the path written
    def download_to(url, path, timeout: nil)
      url = download_url(url)
      path = path.to_s
      raise ArgumentError, "path must not be empty" if path.empty?

      call_timeout = timeout.nil? ? @timeout : positive_number(timeout, "timeout")
      partial = "#{path}.#{SecureRandom.hex(6)}.part"
      begin
        response = execute(:get, url, json: false, timeout: call_timeout, sink: partial)
        raise_error(response) unless response.status == 200
        File.rename(partial, path)
      ensure
        File.delete(partial) if File.exist?(partial)
      end
      path
    end

    # Deletes a stored file before its link expires: DELETE /v2/d/{file_id}.
    #
    # @param file_id [String] the FileId, 32 hex characters
    # @return [Boolean] true when deleted, false when there was nothing to delete (404)
    def delete_stored_file(file_id)
      unless file_id.is_a?(String) && FILE_ID.match?(file_id)
        raise ArgumentError, "file_id must be 32 hex characters, got #{file_id.inspect}"
      end

      response = execute(:delete, "#{@base_url}/v2/d/#{file_id}", key: require_key)
      return true if response.status == 204 || response.status == 200
      return false if response.status == 404

      raise_error(response)
    end

    private

    # ---- arguments ------------------------------------------------------------------------

    def normalize_key(key)
      return nil if key.nil?
      raise ArgumentError, "api_key must be a String" unless key.is_a?(String)

      key = key.strip
      return nil if key.empty?
      raise ArgumentError, "api_key contains control characters" if key.match?(/[[:cntrl:]]/)

      key.dup.freeze
    end

    def normalize_base_url(base_url)
      if base_url.nil?
        env = ENV.fetch("PDFCONVERSIONAPI_BASE_URL", "").strip
        base_url = env.empty? ? DEFAULT_BASE_URL : env
      end
      raise ArgumentError, "base_url must be a String" unless base_url.is_a?(String)

      url = base_url.strip.sub(%r{/+\z}, "")
      uri = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
        raise ArgumentError, "base_url must be an http or https URL, got #{base_url.inspect}"
      end

      url.freeze
    end

    def positive_number(value, name)
      raise ArgumentError, "#{name} must be a number above 0, got #{value.inspect}" unless value.is_a?(Numeric) && value.positive?

      value
    end

    def format_name(value, name)
      text = value.is_a?(Symbol) ? value.to_s : value
      unless text.is_a?(String) && FORMAT.match?(text)
        raise ArgumentError, "#{name} must be 1 to 20 letters, digits or hyphens, got #{value.inspect}"
      end

      text.downcase
    end

    def check_params(params)
      return {} if params.nil?
      raise ArgumentError, "params must be a Hash, got #{params.class}" unless params.respond_to?(:each_pair)

      params.each_pair.map do |name, value|
        unless name.is_a?(String) || name.is_a?(Symbol)
          raise ArgumentError, "parameter names must be Strings or Symbols, got #{name.inspect}"
        end

        [name.to_s, value]
      end
    end

    def require_key
      @api_key || raise(MissingApiKeyError,
                        "no API key: pass api_key: to PdfConversionApi::Client.new or set PDFCONVERSIONAPI_KEY")
    end

    def download_url(url)
      text = url.to_s
      uri = begin
        URI.parse(text)
      rescue URI::InvalidURIError
        nil
      end
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
        raise ArgumentError, "url must be an http or https URL, got #{url.inspect}"
      end

      text
    end

    # ---- the request body --------------------------------------------------------------------

    def build_form(uploads, params, file_name, store_file)
      form = Multipart.new
      field = uploads.length == 1 ? "File" : "Files"
      uploads.each { |upload| form.add_file(field, upload) }

      replaced = []
      replaced << "filename" unless file_name.nil?
      replaced << "storefile" unless store_file.nil?
      params.each do |name, value|
        next if value.nil? || replaced.include?(name.downcase)

        if UploadFile.file_like?(value)
          form.add_file(name, UploadFile.coerce(value))
        else
          form.add_text(name, param_text(name, value))
        end
      end
      form.add_text("FileName", file_name) unless file_name.nil?
      form.add_text("StoreFile", "true") if store_file
      form
    end

    def param_text(name, value)
      case value
      when String then value
      when Symbol then value.to_s
      when true, false then value.to_s
      when Integer then value.to_s
      when Float then plain_decimal(name, value)
      when Rational then plain_decimal(name, value.to_f)
      else
        return value.to_s("F") if defined?(BigDecimal) && value.is_a?(BigDecimal) && value.finite?

        raise ArgumentError,
              "parameter #{name} must be a String, number, boolean, Symbol, nil or a file, got #{value.class}"
      end
    end

    # A float in plain decimal: 72.0 => "72", 1.5 => "1.5", 1.0e-05 => "0.00001".
    def plain_decimal(name, value)
      raise ArgumentError, "parameter #{name} must be a finite number" unless value.finite?
      return value.to_i.to_s if value == value.truncate

      text = value.to_s
      return text unless text.include?("e")

      mantissa, exponent = text.split("e")
      sign = mantissa.start_with?("-") ? "-" : ""
      whole, fraction = mantissa.delete_prefix("-").split(".")
      digits = whole + fraction.to_s
      point = whole.length + exponent.to_i
      plain =
        if point <= 0 then "0.#{'0' * -point}#{digits}"
        elsif point >= digits.length then digits + ("0" * (point - digits.length))
        else "#{digits[0...point]}.#{digits[point..]}"
        end
      plain = plain.sub(/\.?0+\z/, "") if plain.include?(".")
      sign + plain
    end

    # ---- sending, with retries (SPEC section 8) ------------------------------------------------

    def execute(method, url, key: nil, form: nil, json: true, timeout: @timeout, sink: nil)
      attempt = 1
      retried_500 = false
      loop do
        begin
          response = send_once(method, url, key, form, json, timeout, sink)
        rescue BodyFailure => e
          raise ConnectionError.new(
            "the connection to #{URI.parse(url).host} dropped while the response was being read " \
            "(#{e.cause.class}: #{e.cause.message}). Not retried: the conversion may already have run " \
            "and counted toward this month."
          ), cause: e.cause
        rescue Net::ReadTimeout, Net::WriteTimeout, Deadline
          raise TimeoutError,
                "no complete response within #{timeout} seconds. The conversion may still be running on " \
                "the server, and it counts toward this month if it succeeds. Raise the timeout with " \
                "timeout: (per client or per call)."
        rescue *CONNECTION_FAILURES => e
          if attempt <= @max_retries && retryable_failure?(e)
            pause(jitter(attempt))
            attempt += 1
            next
          end
          raise ConnectionError,
                "no response from #{URI.parse(url).host} after #{attempt} attempt#{'s' if attempt > 1}: " \
                "#{e.class}: #{e.message}"
        end

        status = response.status
        if [429, 503].include?(status)
          wait = retry_after(response) || 1
          if attempt <= @max_retries && wait <= @max_retry_wait
            pause(wait + jitter(attempt))
            attempt += 1
            next
          end
        elsif status == 500 && !retried_500 && attempt <= @max_retries
          retried_500 = true
          pause(1 + jitter(attempt))
          attempt += 1
          next
        end
        return response
      end
    end

    # A certificate that fails verification won't verify on the next attempt either.
    def retryable_failure?(error)
      !(error.is_a?(OpenSSL::SSL::SSLError) && error.message.match?(/certificate|verify/i))
    end

    def jitter(attempt)
      Random.rand * (2**attempt)
    end

    def pause(seconds)
      @sleeper.call(seconds)
    end

    # One attempt. Returns the response with its body read, or raises the transport's error.
    def send_once(method, url, key, form, json, timeout, sink)
      uri = URI.parse(url)
      request = new_request(method, uri, key, json)
      body_stream = nil
      if form
        body_stream, length = form.stream
        request["Content-Type"] = form.content_type
        request.content_length = length
        request.body_stream = body_stream
      end

      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @connect_timeout # also covers the TLS handshake
      http.read_timeout = timeout
      http.write_timeout = timeout
      http.max_retries = 0 # every retry goes through #execute
      http.ignore_eof = false if http.respond_to?(:ignore_eof=) # a short body is an error

      response = nil
      Timeout.timeout(timeout, Deadline) do
        http.start do |connection|
          connection.request(request) { |res| response = read_response(res, sink) }
        end
      end
      response
    ensure
      body_stream&.close
    end

    def new_request(method, uri, key, json)
      headers = { "User-Agent" => USER_AGENT, "Accept" => json ? "application/json" : "*/*" }
      headers["Authorization"] = "Bearer #{key}" if key
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
      klass.new(uri.request_uri, headers)
    end

    # Reads the status, headers and body. A transport error from here on is raised as
    # BodyFailure: the status line has arrived, so the request may have done its work.
    def read_response(res, sink)
      status = res.code.to_i
      headers = {}
      res.each_header { |name, value| headers[name] = value }
      expected = expected_length(headers)
      received = 0
      body = +"".b
      begin
        if sink && status == 200
          File.open(sink, "wb") do |file|
            res.read_body do |chunk|
              received += chunk.bytesize
              file.write(chunk)
            end
          end
        else
          res.read_body do |chunk|
            received += chunk.bytesize
            body << chunk
          end
        end
        # Older Net::HTTP versions return a short body without an error when the connection
        # closes early; count the bytes ourselves.
        raise EOFError, "the body ended after #{received} of #{expected} bytes" if expected && received < expected
      rescue *BODY_FAILURES
        raise BodyFailure
      end
      Response.new(status, headers, body)
    end

    # The body length to expect: Content-Length, unless the body is compressed or chunked.
    def expected_length(headers)
      return nil if headers["transfer-encoding"]
      return nil unless [nil, "", "identity"].include?(headers["content-encoding"].to_s.strip.downcase)

      length = headers["content-length"].to_s.strip
      length.match?(/\A\d+\z/) ? length.to_i : nil
    end

    def retry_after(response)
      value = response.headers["retry-after"]
      value && value.strip.match?(/\A\d+\z/) ? value.strip.to_i : nil
    end

    # ---- responses ---------------------------------------------------------------------------

    def parse_json(response)
      JSON.parse(utf8(response.body))
    rescue JSON::ParserError => e
      raise InvalidResponseError.new("the response is not valid JSON (#{e.class})", status: response.status,
                                                                                     request_id: response.request_id)
    end

    def raise_error(response)
      status = response.status
      text = utf8(response.body)
      retry_after = retry_after(response)
      retry_after ||= 1 if [429, 503].include?(status)
      klass = ERROR_CLASSES.fetch(status, ApiError)
      raise klass.new(error_message(text, response.headers["content-type"]), status: status,
                                                                             request_id: response.request_id,
                                                                             retry_after: retry_after, body: text)
    end

    # SPEC section 9: the message of an error response.
    def error_message(text, content_type)
      return "empty response" if text.strip.empty?

      begin
        parsed = JSON.parse(text)
        return parsed["Message"] if parsed.is_a?(Hash) && parsed["Message"].is_a?(String)
      rescue JSON::ParserError
        # not JSON; fall through
      end
      mime = content_type.to_s.split(";").first.to_s.strip.downcase
      return text.strip if mime == "text/plain" && text.length <= 1000

      "non-JSON response (#{mime.empty? ? 'no content type' : mime})"
    end

    def utf8(bytes)
      bytes.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
