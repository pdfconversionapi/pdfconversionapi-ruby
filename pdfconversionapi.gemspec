# frozen_string_literal: true

require_relative "lib/pdfconversionapi/version"

Gem::Specification.new do |spec|
  spec.name = "pdfconversionapi"
  spec.version = PdfConversionApi::VERSION
  spec.authors = ["Zeel Shekhaliya"]
  spec.summary = "Ruby client for the PDF Conversion API: convert documents, images and PDFs with one call."
  spec.description = "The official Ruby SDK for https://pdfconversionapi.com. Convert files between formats, " \
                     "merge, split, compress and watermark PDFs, with typed results, typed errors and " \
                     "retries that follow the API's rules. Uses only Ruby's standard library."
  spec.homepage = "https://pdfconversionapi.com/docs"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => "https://pdfconversionapi.com/docs",
    "documentation_uri" => "https://pdfconversionapi.com/docs",
    "source_code_uri" => "https://github.com/pdfconversionapi/pdfconversionapi-ruby",
    "bug_tracker_uri" => "https://github.com/pdfconversionapi/pdfconversionapi-ruby/issues",
    "changelog_uri" => "https://github.com/pdfconversionapi/pdfconversionapi-ruby/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
