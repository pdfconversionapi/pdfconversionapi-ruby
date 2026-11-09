# frozen_string_literal: true

# Every error is a PdfConversionApi::Error. API errors carry the status, the API's message and
# the request id to quote when you write to support.
require "pdfconversionapi"

client = PdfConversionApi::Client.new
begin
  client.convert_file("report.docx", "dwg")
rescue PdfConversionApi::NotFoundError => e
  puts e.status     # 404
  puts e.message    # the API's own message
  puts e            # adds the status and the request id
rescue PdfConversionApi::RateLimitError, PdfConversionApi::ServiceUnavailableError => e
  warn "busy or out of conversions; try again in #{e.retry_after} seconds"
rescue PdfConversionApi::ApiError => e
  warn "the API refused the request: #{e}"
rescue PdfConversionApi::TimeoutError, PdfConversionApi::ConnectionError => e
  warn "no answer: #{e.message}"
end
