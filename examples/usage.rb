# frozen_string_literal: true

# Your plan, its limits and this month's count. Doesn't use a conversion.
require "pdfconversionapi"

client = PdfConversionApi::Client.new
usage = client.usage
puts "#{usage.plan}: #{usage.used} of #{usage.included} used, #{usage.remaining} left"
puts "resets at #{usage.period_end}"
