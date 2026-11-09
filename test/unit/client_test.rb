# frozen_string_literal: true

require_relative "scripted_client"

class ClientTest < Minitest::Test
  include FormParsing

  Client = PdfConversionApi::Client
  OK = ScriptedClient::OK

  def hello
    TestSupport.fixture("hello.txt")
  end

  # ---- construction --------------------------------------------------------------------------

  def test_defaults
    TestSupport.with_env("PDFCONVERSIONAPI_KEY" => nil, "PDFCONVERSIONAPI_BASE_URL" => nil) do
      client = Client.new
      assert_equal "https://api.pdfconversionapi.com", client.base_url
      assert_equal 240, client.timeout
      assert_equal 10, client.connect_timeout
      assert_equal 4, client.max_retries
      assert_equal 60, client.max_retry_wait
      refute client.api_key?
      assert client.frozen?
    end
  end

  def test_environment
    TestSupport.with_env("PDFCONVERSIONAPI_KEY" => "env-key-0123456789",
                         "PDFCONVERSIONAPI_BASE_URL" => "http://localhost:9999/") do
      client = Client.new
      assert client.api_key?
      assert_equal "http://localhost:9999", client.base_url
      assert_equal "http://other", Client.new(base_url: "http://other").base_url
    end
    TestSupport.with_env("PDFCONVERSIONAPI_KEY" => "", "PDFCONVERSIONAPI_BASE_URL" => "") do
      client = Client.new
      refute client.api_key?
      assert_equal "https://api.pdfconversionapi.com", client.base_url
    end
  end

  def test_trailing_slashes_are_ignored
    assert_equal "http://h:1/prefix", Client.new(base_url: "http://h:1/prefix//").base_url
  end

  def test_invalid_options
    assert_raises(ArgumentError) { Client.new(base_url: "ftp://h") }
    assert_raises(ArgumentError) { Client.new(base_url: "not a url") }
    assert_raises(ArgumentError) { Client.new(timeout: 0) }
    assert_raises(ArgumentError) { Client.new(timeout: "240") }
    assert_raises(ArgumentError) { Client.new(connect_timeout: -1) }
    assert_raises(ArgumentError) { Client.new(max_retries: -1) }
    assert_raises(ArgumentError) { Client.new(max_retries: 1.5) }
    assert_raises(ArgumentError) { Client.new(max_retry_wait: -1) }
    assert_raises(ArgumentError) { Client.new(sleeper: 5) }
    assert_raises(ArgumentError) { Client.new(api_key: 123) }
  end

  def test_the_key_never_shows
    key = "sk_live_supersecret_0123456789"
    client = Client.new(api_key: key)
    refute_includes client.inspect, key
    refute_includes client.to_s, key
    require "pp"
    refute_includes client.pretty_inspect, key
    error = assert_raises(ArgumentError) { Client.new(api_key: "#{key}\nX-Evil: 1") }
    refute_includes error.message, key
  end

  # ---- arguments -----------------------------------------------------------------------------

  def test_formats_are_validated_and_lowercased
    client = ScriptedClient.new([OK])
    client.convert(:TXT, "Pdf", hello)
    assert_equal "http://api.test/v2/convert/txt/to/pdf", client.sent.last.url

    ["../etc", "", "a" * 21, "pdf ", "p/df", nil, 5].each do |bad|
      assert_raises(ArgumentError, "from=#{bad.inspect}") { client.convert(bad, "pdf", hello) }
      assert_raises(ArgumentError, "to=#{bad.inspect}") { client.convert("txt", bad, hello) }
    end
    assert_equal 1, client.sent.length
  end

  def test_without_files_the_request_has_no_file_field
    client = ScriptedClient.new([OK, OK, OK])
    client.convert("data", "qrcode", params: { "Data" => "hello" })
    client.convert("data", "qrcode", nil, params: { "Data" => "hello" })
    client.convert("data", "qrcode", [], params: { "Data" => "hello" })
    client.sent.each_index do |i|
      assert_equal [["Data", nil, "hello"]], sent_fields(client, i).map { |f| [f[:name], f[:filename], f[:data]] }
    end
    assert_raises(ArgumentError) { client.convert("txt", "pdf", 42) }
    assert_raises(ArgumentError) { client.convert("txt", "pdf", [hello, 42]) }
    assert_equal 3, client.sent.length
  end

  def test_missing_key_raises_before_sending
    TestSupport.with_env("PDFCONVERSIONAPI_KEY" => nil) do
      client = ScriptedClient.new([], api_key: nil)
      assert_raises(PdfConversionApi::MissingApiKeyError) { client.convert("txt", "pdf", hello) }
      assert_raises(PdfConversionApi::MissingApiKeyError) { client.convert_file(hello, "pdf") }
      assert_raises(PdfConversionApi::MissingApiKeyError) { client.usage }
      assert_raises(PdfConversionApi::MissingApiKeyError) { client.delete_stored_file("0" * 32) }
      assert_empty client.sent
    end
  end

  def test_conversions_and_downloads_need_no_key
    info = JSON.generate([{ From: "docx", To: "pdf", Title: "DOCX to PDF", Category: "Document", Inputs: "one" }])
    TestSupport.with_env("PDFCONVERSIONAPI_KEY" => nil) do
      client = ScriptedClient.new([[200, {}, info], [200, {}, "bytes"]], api_key: nil)
      list = client.conversions
      assert_equal 1, list.length
      assert_equal "docx", list.first.from
      assert_equal "pdf", list.first.to_format
      assert_equal "bytes", client.download("http://api.test/v2/d/#{'a' * 32}/x.pdf")
      assert(client.sent.all? { |s| s.key.nil? })
    end
  end

  def test_with_a_key_only_api_calls_send_it
    client = ScriptedClient.new([[200, {}, "[]"], [200, {}, "bytes"], OK])
    client.conversions
    client.download("http://cdn.test/file.pdf")
    client.convert("txt", "pdf", hello)
    assert_equal [nil, nil, ScriptedClient::KEY], client.sent.map(&:key)
  end

  def test_convert_file_reads_the_format_from_the_extension
    Dir.mktmpdir do |dir|
      path = File.join(dir, "REPORT.Docx")
      File.binwrite(path, "x")
      client = ScriptedClient.new([OK])
      client.convert_file(path, "pdf", params: { "A" => 1 })
      assert_equal "http://api.test/v2/convert/docx/to/pdf", client.sent.last.url
      assert_equal "REPORT.Docx", sent_fields(client).first[:filename]

      File.binwrite(File.join(dir, "noext"), "x")
      error = assert_raises(ArgumentError) { client.convert_file(File.join(dir, "noext"), "pdf") }
      assert_match(/no extension/, error.message)
      assert_raises(ArgumentError) { client.convert_file(File.join(dir, ".hidden"), "pdf") }
    end
  end

  def test_missing_input_file
    client = ScriptedClient.new
    assert_raises(Errno::ENOENT) { client.convert("txt", "pdf", "/nonexistent/in.txt") }
    assert_empty client.sent
  end

  def test_delete_stored_file
    client = ScriptedClient.new([[204, {}, ""], [404, { "Content-Type" => "application/json" },
                                                 '{"Code":404,"Message":"not found"}']])
    assert_equal true, client.delete_stored_file("ab" * 16)
    assert_equal false, client.delete_stored_file("AB" * 16)
    assert_equal [:delete, "http://api.test/v2/d/#{'ab' * 16}"], [client.sent.first.method, client.sent.first.url]
    ["", "abc", "g" * 32, "a" * 33, nil].each do |bad|
      assert_raises(ArgumentError) { client.delete_stored_file(bad) }
    end
    error_client = ScriptedClient.new([[401, {}, '{"Code":401,"Message":"a valid API key is required"}']])
    assert_raises(PdfConversionApi::AuthenticationError) { error_client.delete_stored_file("0" * 32) }
  end

  def test_download_url_must_be_http
    client = ScriptedClient.new
    ["file:///etc/passwd", "/v2/d/x/y", "", nil].each do |bad|
      assert_raises(ArgumentError) { client.download(bad) }
    end
  end

  def test_per_call_timeout_is_validated
    client = ScriptedClient.new
    assert_raises(ArgumentError) { client.convert("txt", "pdf", hello, timeout: 0) }
    assert_raises(ArgumentError) { client.convert("txt", "pdf", hello, store_file: "yes") }
    assert_raises(ArgumentError) { client.convert("txt", "pdf", hello, file_name: 5) }
    assert_raises(ArgumentError) { client.convert("txt", "pdf", hello, params: [1, 2]) }
    assert_raises(ArgumentError) { client.convert("txt", "pdf", hello, params: { 5 => "x" }) }
  end

  # ---- usage ---------------------------------------------------------------------------------

  def test_usage
    body = JSON.generate(Plan: "Starter", Included: 5000, Used: 7, Remaining: nil, Overage: false, Running: 1,
                         ConcurrentLimit: 4, MaxUploadMB: 100, PeriodStart: "2026-11-01T00:00:00.000Z",
                         PeriodEnd: "2026-12-01T00:00:00+00:00")
    client = ScriptedClient.new([[200, {}, body]])
    usage = client.usage
    assert_equal "http://api.test/v2/usage", client.sent.last.url
    assert_equal "Starter", usage.plan
    assert_nil usage.remaining
    refute usage.overage?
    assert_equal 4, usage.concurrent_limit
    assert_equal 100, usage.max_upload_mb
    assert_equal Time.utc(2026, 11, 1), usage.period_start
    assert usage.period_end.utc?
    assert_equal Time.utc(2026, 12, 1), usage.period_end
  end

  def test_usage_with_a_bad_date
    client = ScriptedClient.new([[200, {}, '{"PeriodStart":"soon"}']])
    assert_raises(PdfConversionApi::InvalidResponseError) { client.usage }
  end
end
