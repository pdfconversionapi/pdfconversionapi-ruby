# frozen_string_literal: true

module PdfConversionApi
  # Base class of every error this gem raises. Bad arguments raise Ruby's own ArgumentError
  # instead.
  class Error < StandardError; end

  # A call that needs an API key was made without one. Raised before anything is sent.
  class MissingApiKeyError < Error; end

  # The data of a stored file (StoreFile) was read. Call OutputFile#download or #download_to.
  class StoredFileError < Error; end

  # No response from the API after every attempt (DNS failure, refused or reset connection,
  # connection closed before a response).
  class ConnectionError < Error; end

  # The client's own timeout ran out. Never retried: the conversion may still be running on the
  # server and counts toward the month if it succeeds.
  class TimeoutError < Error; end

  # A 200 response whose body can't be used: bad JSON, no Files, or data that doesn't match
  # FileSize.
  class InvalidResponseError < Error
    # @return [Integer, nil] the HTTP status
    attr_reader :status
    # @return [String, nil] the x-request-id header
    attr_reader :request_id

    def initialize(message, status: nil, request_id: nil)
      super(message)
      @status = status
      @request_id = request_id
    end
  end

  # An error status from the API. Subclasses name the common statuses; any other status raises
  # ApiError itself.
  #
  # +message+ is the API's own text. +to_s+ (and string interpolation) adds the status and the
  # request id: <tt>HTTP 429: too many requests; slow down (request id: 1a2b...)</tt>.
  class ApiError < Error
    # @return [Integer] the HTTP status
    attr_reader :status
    # @return [String, nil] the x-request-id header, nil when the response had none
    attr_reader :request_id
    # @return [Integer, nil] the Retry-After header in seconds (always set on 429 and 503)
    attr_reader :retry_after
    # @return [String] the raw response body, for debugging
    attr_reader :body

    def initialize(message, status:, request_id: nil, retry_after: nil, body: "")
      @api_message = message
      @status = status
      @request_id = request_id
      @retry_after = retry_after
      @body = body
      super(format_full)
    end

    # The API's message, unchanged.
    def message
      @api_message
    end

    # The message with the status and the request id.
    def to_s
      format_full
    end

    # Ruby 3.2+ prints uncaught errors with this: show the status and the request id too.
    def detailed_message(highlight: false, **_opts)
      text = "#{format_full} (#{self.class.name})"
      highlight ? "\e[1m#{text}\e[m" : text
    end

    private

    def format_full
      text = "HTTP #{@status}: #{@api_message}"
      text += " (request id: #{@request_id})" if @request_id
      text
    end
  end

  # 400: the request is wrong (a parameter, a page range, the number of files...).
  class BadRequestError < ApiError; end
  # 401: the key is missing, unknown or replaced.
  class AuthenticationError < ApiError; end
  # 403: the key's plan isn't set up.
  class PermissionDeniedError < ApiError; end
  # 404: unsupported conversion, or a stored file that expired or was deleted.
  class NotFoundError < ApiError; end
  # 413: the request or an image is over a limit.
  class PayloadTooLargeError < ApiError; end
  # 422: the file can't be read or converted as asked.
  class UnprocessableEntityError < ApiError; end
  # 429: rate limit, conversions at once, or the month's conversions used up (see retry_after).
  class RateLimitError < ApiError; end
  # 500: an unexpected failure on the server.
  class InternalServerError < ApiError; end
  # 503: the servers are busy, or conversions on the plan are paused (see retry_after).
  class ServiceUnavailableError < ApiError; end
  # 504: the conversion ran out of time on the server.
  class GatewayTimeoutError < ApiError; end

  # Status code to error class.
  ERROR_CLASSES = {
    400 => BadRequestError,
    401 => AuthenticationError,
    403 => PermissionDeniedError,
    404 => NotFoundError,
    413 => PayloadTooLargeError,
    422 => UnprocessableEntityError,
    429 => RateLimitError,
    500 => InternalServerError,
    503 => ServiceUnavailableError,
    504 => GatewayTimeoutError
  }.freeze
end
