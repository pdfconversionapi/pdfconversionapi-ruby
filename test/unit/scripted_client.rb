# frozen_string_literal: true

require_relative "../test_helper"

# A client whose transport is a script: each attempt takes the next step, either
# [status, headers, body], an exception to raise before any response, or
# [:after_status_line, ExceptionClass] for a transport error while the body is read.
# Records what was sent and every wait.
class ScriptedClient < PdfConversionApi::Client
  KEY = "sk_test_0123456789abcdef"
  # A 200 with one output, hello.pdf.
  OK = [200, { "Content-Type" => "application/json", "x-request-id" => "req-1" },
        TestSupport.success_body("hello.pdf" => "%PDF-1.7 hi")].freeze

  # Each sent attempt: method, url, the Authorization header value and the body (or nil).
  Sent = Struct.new(:method, :url, :key, :body, :boundary)

  attr_reader :sent, :sleeps

  def initialize(script = [], **options)
    @script = script.dup
    @sent = []
    @sleeps = []
    sleeps = @sleeps
    defaults = { api_key: KEY, base_url: "http://api.test", sleeper: ->(seconds) { sleeps << seconds } }
    super(**defaults.merge(options))
  end

  private

  def send_once(method, url, key, form, _json, _timeout, _sink)
    @sent << Sent.new(method, url, key, form&.to_s, form&.boundary)
    step = @script.shift
    raise "the script ran out after #{@sent.length - 1} attempts" if step.nil?
    raise step if step.is_a?(Exception)
    if step.is_a?(Array) && step.first == :after_status_line
      begin
        raise step.last
      rescue step.last
        raise BodyFailure
      end
    end
    raise step.new("scripted") if step.is_a?(Class) && step <= Exception

    status, headers, body = step
    Response.new(status, (headers || {}).transform_keys(&:downcase), (body || "").b)
  end
end

module FormParsing
  # Parses a multipart body into [{name:, filename:, data:}] (filename nil for text fields).
  def parse_form(body, boundary)
    body = body.b
    parts = body.split("--#{boundary}".b)
    parts.shift # preamble (empty)
    parts.pop   # "--\r\n" after the closing boundary
    parts.map do |part|
      head, data = part.delete_prefix("\r\n".b).split("\r\n\r\n".b, 2)
      data = data.delete_suffix("\r\n".b)
      disposition = head.lines.find { |l| l.downcase.start_with?("content-disposition") }.to_s
      name = disposition[/; name="([^"]*)"/, 1]
      filename = disposition[/; filename="([^"]*)"/, 1]
      {
        name: name&.force_encoding(Encoding::UTF_8),
        filename: filename&.force_encoding(Encoding::UTF_8),
        data: data
      }
    end
  end

  def sent_fields(client, index = -1)
    sent = client.sent[index]
    parse_form(sent.body, sent.boundary)
  end
end
