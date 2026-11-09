# frozen_string_literal: true

# Renders every page of guide.pdf as a JPG at 72 DPI: one output file per page.
require "pdfconversionapi"

client = PdfConversionApi::Client.new
result = client.convert_file("guide.pdf", "jpg", params: { ImageResolution: 72 })
result.files.each { |file| puts "#{file.name} #{file.size} bytes" }
result.save_all("pages")
