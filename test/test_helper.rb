# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "pdfconversionapi"
require "json"
require "minitest/autorun"
require "net/http"
require "socket"
require "stringio"
require "tmpdir"

module TestSupport
  # The shared conformance suite (mock server, cases, fixtures): PDFCONVERSIONAPI_CONFORMANCE_DIR,
  # else ../conformance next to this SDK (the SDK monorepo), else ./conformance inside it (a
  # repository of its own).
  CONFORMANCE_DIR = ENV.fetch("PDFCONVERSIONAPI_CONFORMANCE_DIR", "").then do |given|
    if given.empty?
      inside = File.expand_path("../conformance", __dir__)
      [File.expand_path("../../conformance", __dir__), inside].find { |dir| File.file?(File.join(dir, "cases.json")) } || inside
    else
      File.expand_path(given, __dir__)
    end
  end
  FIXTURES = File.join(CONFORMANCE_DIR, "fixtures")

  module_function

  def fixture(name)
    File.join(FIXTURES, name)
  end

  # Runs the block with environment variables set (nil removes one), then restores them.
  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # The mock API (../conformance/mock-server.mjs), started once per test process on a random
  # port and stopped when the tests end. PDFCONVERSIONAPI_MOCK_URL points the tests at a mock
  # that is already running instead (for example from a container without Node.js).
  module Mock
    class << self
      def url
        @url ||= ENV.fetch("PDFCONVERSIONAPI_MOCK_URL", "").strip.delete_suffix("/").then do |given|
          given.empty? ? start : given
        end
      end

      def attempts(mock_id)
        uri = URI("#{url}/__mock/attempts/#{URI.encode_www_form_component(mock_id)}")
        JSON.parse(Net::HTTP.get(uri)).fetch("attempts")
      end

      private

      def start
        script = File.join(CONFORMANCE_DIR, "mock-server.mjs")
        io = IO.popen(["node", script, "--port", "0"], "r")
        line = io.gets.to_s
        raise "the mock didn't start: #{line.inspect}" unless line.start_with?("LISTENING ")

        Minitest.after_run do
          begin
            Process.kill("TERM", io.pid)
          rescue Errno::ESRCH
            nil
          end
          io.close
        end
        line.split(" ", 2).last.strip
      end
    end
  end

  # A tiny HTTP server for unit tests. The handler gets each request and returns
  # [status, headers, body], :drop (close without answering), or :raw (it wrote to the socket).
  class FakeServer
    Request = Struct.new(:method, :target, :headers, :body)

    attr_reader :url, :requests

    def initialize(&handler)
      @handler = handler
      @server = TCPServer.new("127.0.0.1", 0)
      @url = "http://127.0.0.1:#{@server.addr[1]}"
      @requests = []
      @thread = Thread.new { serve }
      @thread.report_on_exception = false
    end

    def close
      @thread.kill
      @server.close
    end

    private

    def serve
      loop do
        socket = @server.accept
        begin
          handle(socket)
        rescue StandardError
          nil
        ensure
          socket.close unless socket.closed?
        end
      end
    end

    def handle(socket)
      method, target = socket.gets.to_s.split
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.strip.downcase] = value.to_s.strip
      end
      body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : ""
      request = Request.new(method, target, headers, body)
      @requests << request
      result = @handler.call(request, socket)
      return if result == :raw
      return socket.close if result == :drop

      status, response_headers, response_body = result
      response_body = response_body.to_s.b
      head = +"HTTP/1.1 #{status} Status\r\n"
      response_headers.each { |k, v| head << "#{k}: #{v}\r\n" }
      head << "Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n"
      socket.write(head.b + response_body)
    end
  end

  # A JSON success body holding +files+ ({name => data}).
  def success_body(files)
    entries = files.map do |name, data|
      { "FileName" => name, "FileExt" => File.extname(name).delete_prefix("."), "FileSize" => data.bytesize,
        "FileData" => [data].pack("m0") }
    end
    JSON.generate("ConversionCost" => 1, "ConversionTime" => 0.01, "Files" => entries)
  end
end
