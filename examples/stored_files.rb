# frozen_string_literal: true

# Stores the result instead of returning its data, downloads it to disk, then deletes the
# stored copy before its link expires.
require "pdfconversionapi"

client = PdfConversionApi::Client.new
result = client.convert_file("report.docx", "pdf", store_file: true)
file = result.file
puts "stored #{file.name} as #{file.file_id} (#{file.size} bytes)"

path = file.download_to("report-stored.pdf") # streamed to disk, no API key sent
puts "downloaded #{path}"
puts "deleted: #{client.delete_stored_file(file.file_id)}"       # true
puts "deleted again: #{client.delete_stored_file(file.file_id)}" # false: already gone
