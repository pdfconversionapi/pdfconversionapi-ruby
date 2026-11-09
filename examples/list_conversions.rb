# frozen_string_literal: true

# Every conversion the API offers. Needs no API key.
require "pdfconversionapi"

client = PdfConversionApi::Client.new
conversions = client.conversions
puts "#{conversions.length} conversions"
puts conversions.select { |c| c.from == "docx" }.map(&:to).join(" ")
