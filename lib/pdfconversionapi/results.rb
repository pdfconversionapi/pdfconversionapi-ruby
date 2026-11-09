# frozen_string_literal: true

require "fileutils"
require "time"

module PdfConversionApi
  # One output file of a conversion: its data (decoded already), or for a stored file
  # (store_file: true) the link to download it from.
  class OutputFile
    # @return [String] the file's name, extension included
    attr_reader :name
    # @return [String] the extension in lower case, without the dot
    attr_reader :ext
    # @return [Integer] the size in bytes
    attr_reader :size
    # @return [String, nil] the download link of a stored file (works for 3 hours), else nil
    attr_reader :url
    # @return [String, nil] the id of a stored file (32 hex characters), else nil
    attr_reader :file_id

    class << self
      # Builds an OutputFile from one entry of the response's Files, checking every field.
      #
      # @api private
      def parse(entry, index, client, request_id)
        invalid = lambda do |what|
          raise InvalidResponseError.new("Files[#{index}] #{what}", status: 200, request_id: request_id)
        end
        invalid.call("is not an object") unless entry.is_a?(Hash)

        name = entry["FileName"]
        ext = entry["FileExt"]
        size = entry["FileSize"]
        invalid.call("has no FileName") unless name.is_a?(String) && !name.empty?
        invalid.call("has no FileExt") unless ext.is_a?(String)
        invalid.call("has no FileSize") unless size.is_a?(Integer) && size >= 0

        if entry.key?("FileData")
          encoded = entry["FileData"]
          invalid.call("FileData is not a string") unless encoded.is_a?(String)
          begin
            data = encoded.unpack1("m0")
          rescue ArgumentError
            invalid.call("FileData is not valid base64")
          end
          unless data.bytesize == size
            invalid.call("FileData decodes to #{data.bytesize} bytes, but FileSize says #{size}")
          end
          new(name: name, ext: ext, size: size, data: data, client: client)
        else
          url = entry["Url"]
          file_id = entry["FileId"]
          invalid.call("has neither FileData nor Url") unless url.is_a?(String) && !url.empty?
          invalid.call("has a Url but no FileId") unless file_id.is_a?(String) && !file_id.empty?
          new(name: name, ext: ext, size: size, url: url, file_id: file_id, client: client)
        end
      end

      # The name to write on disk: only the file's own name, never folders. Refuses names that
      # would point somewhere else.
      #
      # @api private
      def safe_name(name)
        own = name.to_s.split(%r{[/\\]}, -1).last.to_s
        if own.empty? || own == "." || own == ".." || own.include?("\0")
          raise InvalidResponseError, "refusing to write a file named #{name.inspect}"
        end

        own
      end
    end

    # @api private
    def initialize(name:, ext:, size:, data: nil, url: nil, file_id: nil, client: nil)
      @name = name.dup.force_encoding(Encoding::UTF_8).freeze
      @ext = ext.freeze
      @size = size
      @data = data&.freeze
      @url = url&.freeze
      @file_id = file_id&.freeze
      @client = client
      freeze
    end

    # Whether the file is stored on the server (store_file: true) instead of in the response.
    def stored?
      !@url.nil?
    end
    alias stored stored?

    # The file's bytes (a binary String).
    #
    # @raise [StoredFileError] for a stored file: call #download or #download_to instead
    # @return [String]
    def data
      if stored?
        raise StoredFileError,
              "#{@name} is stored on the server (store_file: true), so the response has no data; " \
              "call #download or #download_to to fetch it"
      end

      @data
    end
    alias bytes data

    # The file's bytes. A stored file is fetched from its link (no API key is sent); an inline
    # file returns its data.
    #
    # @param timeout [Numeric, nil] seconds for the download, instead of the client's timeout
    # @return [String]
    def download(timeout: nil)
      return @data unless stored?

      client!.download(@url, timeout: timeout)
    end

    # Writes the file to +path+ and returns the path written. If +path+ is an existing folder,
    # the file is written inside it under its own name. A stored file is downloaded and streamed
    # to disk. An existing file is overwritten.
    #
    # @param path [String, Pathname]
    # @param timeout [Numeric, nil] seconds for the download of a stored file
    # @return [String] the path written
    def save(path, timeout: nil)
      target = path.to_s
      raise ArgumentError, "path must not be empty" if target.empty?

      target = File.join(target, self.class.safe_name(@name)) if File.directory?(target)
      write_to(target, timeout: timeout)
    end

    # Same as #save: fetches a stored file to disk, or writes an inline file's data.
    alias download_to save

    # Writes to exactly +target+ (no folder lookup).
    #
    # @api private
    def write_to(target, timeout: nil)
      if stored?
        client!.download_to(@url, target, timeout: timeout)
      else
        File.binwrite(target, @data)
        target
      end
    end

    def to_h
      { name: @name, ext: @ext, size: @size, stored: stored?, url: @url, file_id: @file_id }
    end

    def inspect
      extra = stored? ? " stored file_id=#{@file_id}" : ""
      "#<#{self.class.name} name=#{@name.inspect} ext=#{@ext.inspect} size=#{@size}#{extra}>"
    end

    private

    def client!
      @client || raise(Error, "this OutputFile has no client to download #{@name} with")
    end
  end

  # The result of a conversion: the output files, in the API's order.
  class ConversionResult
    include Enumerable

    # @return [Array<OutputFile>] every output file, in the API's order
    attr_reader :files
    # @return [Integer] conversions counted for this request (always 1)
    attr_reader :conversion_cost
    # @return [Float] seconds the conversion took on the server
    attr_reader :conversion_time
    # @return [String, nil] the x-request-id header of the response
    attr_reader :request_id

    class << self
      # Builds a ConversionResult from a parsed 200 body, checking it.
      #
      # @api private
      def parse(body, request_id, client)
        unless body.is_a?(Hash) && body["Files"].is_a?(Array)
          raise InvalidResponseError.new("the response has no Files array", status: 200, request_id: request_id)
        end

        files = body["Files"].each_with_index.map { |entry, i| OutputFile.parse(entry, i, client, request_id) }
        cost = body["ConversionCost"]
        time = body["ConversionTime"]
        new(
          files: files,
          conversion_cost: cost.is_a?(Numeric) ? cost.to_i : nil,
          conversion_time: time.is_a?(Numeric) ? time.to_f : nil,
          request_id: request_id
        )
      end
    end

    # @api private
    def initialize(files:, conversion_cost:, conversion_time:, request_id:)
      @files = files.freeze
      @conversion_cost = conversion_cost
      @conversion_time = conversion_time
      @request_id = request_id&.freeze
      freeze
    end

    # The first output file, for the common case of one.
    #
    # @return [OutputFile, nil]
    def file
      @files.first
    end

    def each(&block)
      @files.each(&block)
    end

    # Writes every file into +dir+ under its own name, creating the folder if needed and
    # overwriting existing files. Stored files are downloaded.
    #
    # @param dir [String, Pathname]
    # @return [Array<String>] the paths written, in order
    def save_all(dir, timeout: nil)
      dir = dir.to_s
      raise ArgumentError, "dir must not be empty" if dir.empty?

      FileUtils.mkdir_p(dir)
      @files.map { |f| f.write_to(File.join(dir, OutputFile.safe_name(f.name)), timeout: timeout) }
    end

    def inspect
      "#<#{self.class.name} files=#{@files.map(&:name).inspect} request_id=#{@request_id.inspect}>"
    end
  end

  # Your plan, its limits, and this month's count (GET /v2/usage).
  class Usage
    # @return [String] the plan's name, such as "Free"
    attr_reader :plan
    # @return [Integer] successful conversions included each month
    attr_reader :included
    # @return [Integer] successful conversions so far this month
    attr_reader :used
    # @return [Integer, nil] what is left of included this month
    attr_reader :remaining
    # @return [Boolean] whether the plan keeps converting past included
    attr_reader :overage
    # @return [Integer] conversions running for the account right now
    attr_reader :running
    # @return [Integer] conversions the plan runs at the same time
    attr_reader :concurrent_limit
    # @return [Integer] the largest request the plan accepts, in MB
    attr_reader :max_upload_mb
    # @return [Time, nil] start of this month's count (UTC)
    attr_reader :period_start
    # @return [Time, nil] end of this month's count (UTC); the count starts again then
    attr_reader :period_end

    alias overage? overage

    class << self
      # @api private
      def parse(body, request_id)
        unless body.is_a?(Hash)
          raise InvalidResponseError.new("the usage response is not a JSON object", status: 200, request_id: request_id)
        end

        new(
          plan: body["Plan"],
          included: body["Included"],
          used: body["Used"],
          remaining: body["Remaining"],
          overage: body["Overage"],
          running: body["Running"],
          concurrent_limit: body["ConcurrentLimit"],
          max_upload_mb: body["MaxUploadMB"],
          period_start: parse_time(body["PeriodStart"], "PeriodStart", request_id),
          period_end: parse_time(body["PeriodEnd"], "PeriodEnd", request_id)
        )
      end

      private

      def parse_time(value, field, request_id)
        return nil if value.nil?

        Time.iso8601(value.to_s).utc
      rescue ArgumentError
        raise InvalidResponseError.new("#{field} is not a date-time: #{value.inspect}", status: 200,
                                                                                        request_id: request_id)
      end
    end

    # @api private
    def initialize(plan:, included:, used:, remaining:, overage:, running:, concurrent_limit:, max_upload_mb:,
                   period_start:, period_end:)
      @plan = plan
      @included = included
      @used = used
      @remaining = remaining
      @overage = overage
      @running = running
      @concurrent_limit = concurrent_limit
      @max_upload_mb = max_upload_mb
      @period_start = period_start
      @period_end = period_end
      freeze
    end

    def to_h
      {
        plan: @plan, included: @included, used: @used, remaining: @remaining, overage: @overage,
        running: @running, concurrent_limit: @concurrent_limit, max_upload_mb: @max_upload_mb,
        period_start: @period_start, period_end: @period_end
      }
    end

    def inspect
      "#<#{self.class.name} #{to_h.map { |k, v| "#{k}=#{v.inspect}" }.join(' ')}>"
    end
  end

  # One conversion the API offers (an entry of GET /v2/info).
  class Conversion
    # @return [String] the source format, the {from} part of the path
    attr_reader :from
    # @return [String] the target format or tool, the {to} part of the path
    attr_reader :to
    # @return [String] a label, such as "DOCX to PDF"
    attr_reader :title
    # @return [String] the group, such as "Document" or "PDF Tools"
    attr_reader :category
    # @return [String] how many files it takes: "one", "many" or "optional"
    attr_reader :inputs

    alias from_format from
    alias to_format to

    class << self
      # @api private
      def parse(body, request_id)
        unless body.is_a?(Array) && body.all? { |e| e.is_a?(Hash) }
          raise InvalidResponseError.new("the conversions response is not an array of objects", status: 200,
                                                                                                 request_id: request_id)
        end

        body.map do |e|
          new(from: e["From"], to: e["To"], title: e["Title"], category: e["Category"], inputs: e["Inputs"])
        end
      end
    end

    # @api private
    def initialize(from:, to:, title:, category:, inputs:)
      @from = from
      @to = to
      @title = title
      @category = category
      @inputs = inputs
      freeze
    end

    def to_h
      { from: @from, to: @to, title: @title, category: @category, inputs: @inputs }
    end

    def ==(other)
      other.is_a?(Conversion) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    def inspect
      "#<#{self.class.name} #{@from}/to/#{@to} #{@title.inspect} #{@category.inspect} inputs=#{@inputs.inspect}>"
    end
  end
end
