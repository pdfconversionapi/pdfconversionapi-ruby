# frozen_string_literal: true

# Stamps logo.png on every page of invoice.pdf at 30% opacity. The logo goes in its own file
# field, ImageFile: pass it as a Pathname (or an UploadFile), since a String parameter is text.
require "pdfconversionapi"
require "pathname"

client = PdfConversionApi::Client.new
result = client.convert_file("invoice.pdf", "image-watermark",
                             params: { ImageFile: Pathname("logo.png"), Opacity: 30 },
                             file_name: "invoice-stamped")
puts result.file.save(".")
