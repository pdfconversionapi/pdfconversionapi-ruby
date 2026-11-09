# frozen_string_literal: true

# Converts report.docx to PDF and writes out/report.pdf.
# Run: PDFCONVERSIONAPI_KEY=... ruby quick_start.rb
require "pdfconversionapi"

client = PdfConversionApi::Client.new # reads PDFCONVERSIONAPI_KEY
result = client.convert_file("report.docx", "pdf")
paths = result.save_all("out") # writes out/report.pdf
puts paths
