# frozen_string_literal: true

require_relative "scripted_client"

# SPEC section 9: error classes and messages.
class ErrorsTest < Minitest::Test
  def raise_for(status, headers, body)
    client = ScriptedClient.new([[status, headers, body]], max_retries: 0)
    assert_raises(PdfConversionApi::ApiError) { client.convert("txt", "pdf", TestSupport.fixture("hello.txt")) }
  end

  def test_tree
    assert_operator PdfConversionApi::Error, :<, StandardError
    %w[MissingApiKeyError StoredFileError ConnectionError TimeoutError InvalidResponseError ApiError].each do |name|
      assert_operator PdfConversionApi.const_get(name), :<, PdfConversionApi::Error, name
    end
    {
      400 => "BadRequestError", 401 => "AuthenticationError", 403 => "PermissionDeniedError",
      404 => "NotFoundError", 413 => "PayloadTooLargeError", 422 => "UnprocessableEntityError",
      429 => "RateLimitError", 500 => "InternalServerError", 503 => "ServiceUnavailableError",
      504 => "GatewayTimeoutError"
    }.each do |status, name|
      klass = PdfConversionApi.const_get(name)
      assert_operator klass, :<, PdfConversionApi::ApiError
      error = raise_for(status, { "Content-Type" => "application/json" }, %({"Code":#{status},"Message":"m"}))
      assert_instance_of klass, error
      assert_equal status, error.status
    end
  end

  def test_other_statuses_raise_plain_api_error
    error = raise_for(418, {}, '{"Code":418,"Message":"teapot"}')
    assert_instance_of PdfConversionApi::ApiError, error
    assert_equal "teapot", error.message
    error = raise_for(302, { "Location" => "http://elsewhere" }, "")
    assert_instance_of PdfConversionApi::ApiError, error
  end

  def test_json_message
    error = raise_for(422, { "Content-Type" => "application/json", "x-request-id" => "abc123" },
                      '{"Code":422,"Message":"the input file is password-protected"}')
    assert_equal "the input file is password-protected", error.message
    assert_equal "HTTP 422: the input file is password-protected (request id: abc123)", error.to_s
    assert_equal "HTTP 422: the input file is password-protected (request id: abc123)", "#{error}"
    assert_equal "abc123", error.request_id
    assert_equal '{"Code":422,"Message":"the input file is password-protected"}', error.body
    assert_nil error.retry_after
  end

  def test_without_a_request_id
    error = raise_for(413, { "Content-Type" => "text/html" }, "<html><body>413</body></html>")
    assert_equal "non-JSON response (text/html)", error.message
    assert_equal "HTTP 413: non-JSON response (text/html)", error.to_s
    assert_nil error.request_id
    assert_equal "<html><body>413</body></html>", error.body
  end

  def test_empty_body
    error = raise_for(504, { "Content-Type" => "application/json", "x-request-id" => "r" }, "")
    assert_equal "empty response", error.message
    assert_instance_of PdfConversionApi::GatewayTimeoutError, error
  end

  def test_plain_text
    error = raise_for(400, { "Content-Type" => "text/plain; charset=utf-8" },
                      "  Invalid `boundary` for `multipart/form-data` request\n")
    assert_equal "Invalid `boundary` for `multipart/form-data` request", error.message

    long = "x" * 1001
    error = raise_for(400, { "Content-Type" => "text/plain" }, long)
    assert_equal "non-JSON response (text/plain)", error.message
    assert_equal long, error.body

    error = raise_for(400, { "Content-Type" => "text/plain" }, "é" * 1000)
    assert_equal "é" * 1000, error.message
  end

  def test_other_bodies
    assert_equal "non-JSON response (no content type)", raise_for(502, {}, "Bad gateway").message
    assert_equal "non-JSON response (text/html)",
                 raise_for(502, { "Content-Type" => "Text/HTML; charset=UTF-8" }, "<h1>502</h1>").message
    assert_equal "non-JSON response (application/json)",
                 raise_for(400, { "Content-Type" => "application/json" }, '{"error":"other shape"}').message
    assert_equal "non-JSON response (application/json)",
                 raise_for(400, { "Content-Type" => "application/json" }, "{broken").message
  end

  def test_retry_after_on_raised_429_and_503
    error = raise_for(429, { "Retry-After" => "7" }, '{"Code":429,"Message":"slow down"}')
    assert_equal 7, error.retry_after
    error = raise_for(503, {}, '{"Code":503,"Message":"busy"}')
    assert_equal 1, error.retry_after
  end

  def test_detailed_message_shows_status
    skip "detailed_message is Ruby 3.2+" unless Exception.method_defined?(:detailed_message)

    error = raise_for(400, { "x-request-id" => "r1" }, '{"Code":400,"Message":"bad"}')
    assert_equal "HTTP 400: bad (request id: r1) (PdfConversionApi::BadRequestError)", error.detailed_message
    assert_includes error.full_message(highlight: false), "HTTP 400: bad (request id: r1)"
  end

  def test_invalid_responses
    client = ScriptedClient.new([[200, { "x-request-id" => "r9" }, "{not json"]])
    error = assert_raises(PdfConversionApi::InvalidResponseError) do
      client.convert("txt", "pdf", TestSupport.fixture("hello.txt"))
    end
    assert_equal "r9", error.request_id
    assert_equal 200, error.status
  end

  def test_error_text_never_holds_the_key
    client = ScriptedClient.new([[401, {}, '{"Code":401,"Message":"a valid API key is required"}']])
    error = assert_raises(PdfConversionApi::AuthenticationError) do
      client.convert("txt", "pdf", TestSupport.fixture("hello.txt"))
    end
    [error.message, error.to_s, error.inspect, error.full_message].each do |text|
      refute_includes text, ScriptedClient::KEY
    end
  end
end
