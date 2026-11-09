# frozen_string_literal: true

# Ruby client for the PDF Conversion API (https://pdfconversionapi.com/docs).
#
#   require "pdfconversionapi"
#
#   client = PdfConversionApi::Client.new          # reads PDFCONVERSIONAPI_KEY
#   result = client.convert_file("report.docx", "pdf")
#   result.save_all("out")                           # writes out/report.pdf
module PdfConversionApi
end

require_relative "pdfconversionapi/version"
require_relative "pdfconversionapi/errors"
require_relative "pdfconversionapi/upload_file"
require_relative "pdfconversionapi/multipart"
require_relative "pdfconversionapi/results"
require_relative "pdfconversionapi/client"
