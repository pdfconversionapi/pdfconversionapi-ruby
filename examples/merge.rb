# frozen_string_literal: true

# Merges three PDFs, in order, into october-billing.pdf.
require "pdfconversionapi"

client = PdfConversionApi::Client.new
result = client.convert("pdf", "merge", ["invoice.pdf", "terms.pdf", "timesheet.pdf"], file_name: "october-billing")
puts result.file.save(".")
