# frozen_string_literal: true

require_relative "scripted_client"

# The real transport (Net::HTTP) against a small local server.
class HttpTest < Minitest::Test
  KEY = "sk_test_http_0123456789"

  def setup
    @servers = []
  end

  def teardown
    @servers.each(&:close)
  end

  def server(&handler)
    TestSupport::FakeServer.new(&handler).tap { |s| @servers << s }
  end

  def client_for(server, **options)
    sleeps = []
    client = PdfConversionApi::Client.new(api_key: KEY, base_url: server.url, sleeper: ->(s) { sleeps << s },
                                          **options)
    [client, sleeps]
  end

  def ok_body
    TestSupport.success_body("hello.pdf" => File.binread(TestSupport.fixture("hello.txt")))
  end

  def test_convert_request_headers_and_body
    srv = server { [200, { "Content-Type" => "application/json", "x-request-id" => "abc" }, ok_body] }
    client, = client_for(srv)
    result = client.convert("txt", "pdf", TestSupport.fixture("hello.txt"), params: { "PageRange" => "1-2" })
    assert_equal "abc", result.request_id

    request = srv.requests.last
    assert_equal "POST", request.method
    assert_equal "/v2/convert/txt/to/pdf", request.target
    assert_equal "Bearer #{KEY}", request.headers["authorization"]
    assert_equal "application/json", request.headers["accept"]
    assert_match(%r{\Apdfconversionapi-ruby/\d+\.\d+\.\d+ ruby/\d+\.\d+\.\d+\z}, request.headers["user-agent"])
    assert_match(%r{\Amultipart/form-data; boundary=pdfconversionapi-[0-9a-f]{32}\z}, request.headers["content-type"])
    assert_equal request.body.bytesize, request.headers["content-length"].to_i
    assert_includes request.body, "name=\"PageRange\"\r\n\r\n1-2\r\n"
    assert_includes request.body, File.binread(TestSupport.fixture("hello.txt"))
  end

  def test_download_sends_no_key
    srv = server { [200, { "Content-Type" => "application/pdf" }, "%PDF-data"] }
    client, = client_for(srv)
    assert_equal "%PDF-data", client.download("#{srv.url}/v2/d/#{'a' * 32}/My%20File.pdf")
    request = srv.requests.last
    assert_equal "GET", request.method
    assert_equal "/v2/d/#{'a' * 32}/My%20File.pdf", request.target
    assert_nil request.headers["authorization"]
    refute_includes request.headers.values.join, KEY
  end

  def test_download_to_streams_to_disk
    data = Random.new(1).bytes(300_000)
    srv = server { [200, { "Content-Type" => "application/octet-stream" }, data] }
    client, = client_for(srv)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.bin")
      File.binwrite(path, "old")
      assert_equal path, client.download_to("#{srv.url}/x", Pathname(path))
      assert_equal data, File.binread(path)
      assert_equal ["out.bin"], Dir.children(dir)
    end
  end

  def test_failed_download_leaves_nothing_behind
    srv = server { [404, { "Content-Type" => "application/json" }, '{"Code":404,"Message":"not found"}'] }
    client, = client_for(srv)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.pdf")
      error = assert_raises(PdfConversionApi::NotFoundError) { client.download_to("#{srv.url}/x", path) }
      assert_equal "not found", error.message
      assert_empty Dir.children(dir)

      File.binwrite(path, "keep me")
      assert_raises(PdfConversionApi::NotFoundError) { client.download_to("#{srv.url}/x", path) }
      assert_equal "keep me", File.binread(path)
    end
  end

  def test_redirects_are_not_followed
    srv = server { [302, { "Location" => "http://example.com/elsewhere" }, ""] }
    client, = client_for(srv)
    error = assert_raises(PdfConversionApi::ApiError) { client.download("#{srv.url}/x") }
    assert_equal 302, error.status
    assert_equal 1, srv.requests.length
  end

  def test_the_timeout_covers_the_whole_response
    # Headers at once, then one byte every 0.2 s: no single read waits long, but the whole
    # response takes far longer than the timeout.
    srv = server do |_request, socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n")
      20.times do
        socket.write("x")
        sleep 0.2
      end
      :raw
    end
    client, sleeps = client_for(srv, timeout: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(PdfConversionApi::TimeoutError) { client.conversions }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 2.5
    assert_match(/within 1 seconds/, error.message)
    assert_equal 1, srv.requests.length
    assert_empty sleeps
  end

  def test_connection_refused_is_retried_then_raised
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    sleeps = []
    client = PdfConversionApi::Client.new(api_key: KEY, base_url: "http://127.0.0.1:#{port}", max_retries: 2,
                                          sleeper: ->(s) { sleeps << s })
    error = assert_raises(PdfConversionApi::ConnectionError) { client.usage }
    assert_equal 2, sleeps.length
    assert_match(/after 3 attempts/, error.message)
    refute_includes error.message, KEY
  end

  def test_dropped_connection_then_success
    count = 0
    srv = server do
      count += 1
      count == 1 ? :drop : [200, { "Content-Type" => "application/json" }, ok_body]
    end
    client, sleeps = client_for(srv)
    assert_equal "hello.pdf", client.convert("txt", "pdf", TestSupport.fixture("hello.txt")).file.name
    assert_equal 2, srv.requests.length
    assert_equal 1, sleeps.length
    assert_equal srv.requests[0].body.bytesize, srv.requests[1].body.bytesize
  end

  def test_a_body_cut_short_raises_at_once
    srv = server do |_request, socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n")
      socket.write('{"ConversionCost":1,"Files":[')
      socket.close
      :raw
    end
    client, sleeps = client_for(srv)
    error = assert_raises(PdfConversionApi::ConnectionError) { client.convert("txt", "pdf", TestSupport.fixture("hello.txt")) }
    assert_match(/dropped while the response was being read/, error.message)
    assert_equal 1, srv.requests.length
    assert_empty sleeps

    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.pdf")
      assert_raises(PdfConversionApi::ConnectionError) { client.download_to("#{srv.url}/x", path) }
      assert_empty Dir.children(dir)
    end
  end

  def test_a_gzip_body_is_decoded
    require "zlib"
    payload = ok_body
    gz = StringIO.new(+"".b)
    writer = Zlib::GzipWriter.new(gz)
    writer.write(payload)
    writer.close
    srv = server { [200, { "Content-Type" => "application/json", "Content-Encoding" => "gzip" }, gz.string] }
    client, = client_for(srv)
    assert_equal "hello.pdf", client.convert("txt", "pdf", TestSupport.fixture("hello.txt")).file.name
  end

  def test_one_client_shared_between_threads
    srv = server { |request| [200, { "Content-Type" => "application/json" }, TestSupport.success_body(request.target.split("/").last + ".out" => request.target)] }
    client, = client_for(srv)
    results = Array.new(8) do |i|
      Thread.new { client.convert("txt", "f#{i}", PdfConversionApi::UploadFile.from_bytes("x", "in.txt")) }
    end.map(&:value)
    assert_equal (0...8).map { |i| "f#{i}.out" }, results.map { |r| r.file.name }
    assert_equal (0...8).map { |i| "/v2/convert/txt/to/f#{i}" }, results.map { |r| r.file.data }
  end
end
