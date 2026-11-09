# frozen_string_literal: true

# A conversion that takes no file: data/to/qrcode reads its Data parameter.
require "pdfconversionapi"

client = PdfConversionApi::Client.new
result = client.convert("data", "qrcode", params: { Data: "https://pdfconversionapi.com" })
puts result.file.save(".")
