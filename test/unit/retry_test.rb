# frozen_string_literal: true

require_relative "scripted_client"

# SPEC section 8, decision by decision.
class RetryTest < Minitest::Test
  OK = ScriptedClient::OK

  def json_error(status, message, headers = {})
    [status, { "Content-Type" => "application/json", "x-request-id" => "req-#{status}" }.merge(headers),
     JSON.generate("Code" => status, "Message" => message)]
  end

  def convert(client)
    client.convert("txt", "pdf", TestSupport.fixture("hello.txt"))
  end

  def assert_jitter(sleeps, bases)
    assert_equal bases.length, sleeps.length, "number of waits"
    sleeps.zip(bases).each_with_index do |(slept, base), i|
      attempt = i + 1
      assert_operator slept, :>=, base
      assert_operator slept, :<, base + (2**attempt), "wait #{attempt}: #{slept}"
    end
  end

  def test_503_then_success
    busy = json_error(503, "the server is busy; retry shortly", "Retry-After" => "5")
    client = ScriptedClient.new([busy, busy, OK])
    assert_equal "hello.pdf", convert(client).file.name
    assert_equal 3, client.sent.length
    assert_jitter client.sleeps, [5, 5]
  end

  def test_429_waits_retry_after
    client = ScriptedClient.new([json_error(429, "too many requests; slow down", "Retry-After" => "10"), OK])
    convert(client)
    assert_jitter client.sleeps, [10]
  end

  def test_missing_or_unreadable_retry_after_means_one_second
    no_header = json_error(429, "slow down")
    http_date = json_error(503, "busy", "Retry-After" => "Wed, 21 Oct 2026 07:28:00 GMT")
    client = ScriptedClient.new([no_header, http_date, OK])
    convert(client)
    assert_jitter client.sleeps, [1, 1]
  end

  def test_long_retry_after_is_raised_at_once
    quota = json_error(429, "this month's 250 conversions on the Free plan are used up", "Retry-After" => "2000000")
    client = ScriptedClient.new([quota])
    error = assert_raises(PdfConversionApi::RateLimitError) { convert(client) }
    assert_equal 2_000_000, error.retry_after
    assert_equal 1, client.sent.length
    assert_empty client.sleeps
  end

  def test_max_retry_wait
    client = ScriptedClient.new([json_error(503, "paused", "Retry-After" => "45")], max_retry_wait: 30)
    assert_raises(PdfConversionApi::ServiceUnavailableError) { convert(client) }
    assert_equal 1, client.sent.length

    client = ScriptedClient.new([json_error(503, "busy", "Retry-After" => "45"), OK], max_retry_wait: 45)
    convert(client)
    assert_equal 2, client.sent.length
  end

  def test_gives_up_when_attempts_run_out
    busy = json_error(503, "busy", "Retry-After" => "1")
    client = ScriptedClient.new([busy] * 3, max_retries: 2)
    error = assert_raises(PdfConversionApi::ServiceUnavailableError) { convert(client) }
    assert_equal 1, error.retry_after
    assert_equal 3, client.sent.length
    assert_jitter client.sleeps, [1, 1]
  end

  def test_retries_disabled
    client = ScriptedClient.new([json_error(429, "slow down", "Retry-After" => "1")], max_retries: 0)
    assert_raises(PdfConversionApi::RateLimitError) { convert(client) }
    assert_equal 1, client.sent.length
  end

  def test_500_is_retried_once_per_call
    client = ScriptedClient.new([json_error(500, "internal error"), json_error(500, "internal error")])
    error = assert_raises(PdfConversionApi::InternalServerError) { convert(client) }
    assert_equal "internal error", error.message
    assert_equal 2, client.sent.length
    assert_jitter client.sleeps, [1]

    client = ScriptedClient.new([json_error(500, "internal error"), OK])
    convert(client)
    assert_equal 2, client.sent.length

    busy = json_error(503, "busy", "Retry-After" => "1")
    client = ScriptedClient.new([json_error(500, "x"), busy, json_error(500, "y")])
    assert_equal "y", assert_raises(PdfConversionApi::InternalServerError) { convert(client) }.message
    assert_equal 3, client.sent.length
  end

  def test_500_with_no_retries_left
    client = ScriptedClient.new([json_error(500, "internal error")], max_retries: 0)
    assert_raises(PdfConversionApi::InternalServerError) { convert(client) }
    assert_equal 1, client.sent.length
  end

  def test_never_retried
    [400, 401, 403, 404, 413, 422, 504, 418].each do |status|
      client = ScriptedClient.new([json_error(status, "nope")])
      assert_raises(PdfConversionApi::ApiError) { convert(client) }
      assert_equal 1, client.sent.length, "status #{status}"
      assert_empty client.sleeps
    end
  end

  def test_connection_failures_are_retried_with_backoff
    client = ScriptedClient.new([Errno::ECONNREFUSED, EOFError, Errno::ECONNRESET, SocketError, Net::OpenTimeout])
    error = assert_raises(PdfConversionApi::ConnectionError) { convert(client) }
    assert_equal 5, client.sent.length
    assert_jitter client.sleeps, [0, 0, 0, 0]
    assert_match(/after 5 attempts/, error.message)
    assert_kind_of Net::OpenTimeout, error.cause
  end

  def test_connection_failure_then_success
    client = ScriptedClient.new([Errno::ECONNRESET, OK])
    assert_equal "hello.pdf", convert(client).file.name
    assert_equal 2, client.sent.length
  end

  def test_a_failure_after_the_status_line_is_not_retried
    [Errno::ECONNRESET, EOFError, Zlib::BufError].each do |failure|
      client = ScriptedClient.new([[:after_status_line, failure], OK])
      error = assert_raises(PdfConversionApi::ConnectionError) { convert(client) }
      assert_match(/may already have run/, error.message)
      assert_kind_of failure, error.cause
      assert_equal 1, client.sent.length
      assert_empty client.sleeps
    end
  end

  def test_certificate_failures_are_not_retried
    bad_cert = OpenSSL::SSL::SSLError.new("SSL_connect returned=1 errno=0 state=error: certificate verify failed")
    client = ScriptedClient.new([bad_cert])
    assert_raises(PdfConversionApi::ConnectionError) { convert(client) }
    assert_equal 1, client.sent.length
  end

  def test_client_timeouts_are_never_retried
    [Net::ReadTimeout, Net::WriteTimeout].each do |timeout|
      client = ScriptedClient.new([timeout, OK])
      error = assert_raises(PdfConversionApi::TimeoutError) { convert(client) }
      assert_match(/may still be running/, error.message)
      assert_equal 1, client.sent.length
    end
  end

  def test_downloads_and_deletes_use_the_same_loop
    busy = json_error(503, "busy", "Retry-After" => "1")
    client = ScriptedClient.new([busy, Errno::ECONNRESET, [200, {}, "data"]])
    assert_equal "data", client.download("http://api.test/v2/d/#{'a' * 32}/a.pdf")
    assert_equal 3, client.sent.length

    client = ScriptedClient.new([json_error(500, "internal error"), [204, {}, ""]])
    assert client.delete_stored_file("a" * 32)
  end

  def test_the_body_is_rebuilt_for_each_attempt
    client = ScriptedClient.new([Errno::ECONNRESET, OK])
    convert(client)
    first, second = client.sent
    assert_equal first.body.sub(first.boundary, "B"), second.body.sub(second.boundary, "B")
  end
end
