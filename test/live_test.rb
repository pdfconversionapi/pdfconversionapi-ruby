# frozen_string_literal: true

require_relative "test_helper"

# Live tests against the real API (SPEC section 12). The base URL and key come from
# ../conformance/.local-api.env (the API running locally), else from PDFCONVERSIONAPI_LIVE_BASE_URL
# and PDFCONVERSIONAPI_KEY in the environment (the release workflow's run against the production
# API); without either every test is skipped, and the key alone doesn't start them. The key is
# never printed. The input files are in ../conformance/samples. Keep a run small: 6 conversions.
class LiveTest < Minitest::Test
  ENV_FILE = File.join(TestSupport::CONFORMANCE_DIR, ".local-api.env")
  SAMPLES = ENV.fetch("PDFCONVERSIONAPI_SAMPLES_DIR", "").then do |given|
    given.empty? ? File.join(TestSupport::CONFORMANCE_DIR, "samples") : File.expand_path(given, __dir__)
  end

  def self.settings
    @settings ||= if File.exist?(ENV_FILE)
                    values = {}
                    File.foreach(ENV_FILE, encoding: "UTF-8") do |line|
                      next if line.strip.empty? || line.lstrip.start_with?("#")

                      name, value = line.sub(/\Aexport\s+/, "").split("=", 2)
                      values[name.strip] = value.to_s.strip.delete_prefix('"').delete_suffix('"')
                    end
                    { base_url: values["PDFCONVERSIONAPI_LOCAL_BASE_URL"].to_s, key: values["PDFCONVERSIONAPI_LOCAL_KEY"].to_s }
                  else
                    { base_url: ENV.fetch("PDFCONVERSIONAPI_LIVE_BASE_URL", ""), key: ENV.fetch("PDFCONVERSIONAPI_KEY", "") }
                  end
  end

  def setup
    settings = self.class.settings
    if settings[:base_url].empty? || settings[:key].empty?
      skip(File.exist?(ENV_FILE) ? "#{ENV_FILE} lacks the base URL or the key" :
             "no #{ENV_FILE}, and PDFCONVERSIONAPI_LIVE_BASE_URL or PDFCONVERSIONAPI_KEY is not set")
    end
    assert File.file?(sample("docx-to-pdf/input-quarterly-report.docx")),
           "the live tests' sample files are missing from #{SAMPLES}"

    @base_url = settings[:base_url]
    @client = PdfConversionApi::Client.new(api_key: settings[:key], base_url: @base_url)
  end

  def sample(path)
    File.join(SAMPLES, path)
  end

  def test_docx_to_pdf
    result = @client.convert_file(sample("docx-to-pdf/input-quarterly-report.docx"), "pdf")
    assert_equal 1, result.conversion_cost
    assert_kind_of Float, result.conversion_time
    refute_empty result.request_id.to_s
    assert_equal ["input-quarterly-report.pdf"], result.files.map(&:name)
    assert_equal "pdf", result.file.ext
    assert result.file.data.start_with?("%PDF-")
    assert_equal result.file.size, result.file.data.bytesize
  end

  def test_pdf_to_jpg_two_outputs
    result = @client.convert_file(sample("pdf-to-jpg/input-season-guide.pdf"), "jpg",
                                  params: { ImageResolution: 72 })
    assert_equal %w[input-season-guide-1.jpg input-season-guide-2.jpg], result.files.map(&:name)
    result.files.each { |f| assert f.data.start_with?("\xFF\xD8".b), f.name }
    Dir.mktmpdir do |dir|
      paths = result.save_all(File.join(dir, "pages"))
      assert_equal result.files.map(&:size), paths.map { |p| File.size(p) }
    end
  end

  def test_merge_three_pdfs
    inputs = %w[input-invoice.pdf input-terms.pdf input-timesheet.pdf].map { |n| sample("merge/#{n}") }
    result = @client.convert("pdf", "merge", inputs, file_name: "october-billing")
    assert_equal ["october-billing.pdf"], result.files.map(&:name)
    assert result.file.data.start_with?("%PDF-")
  end

  def test_store_file_download_and_delete
    result = @client.convert_file(sample("docx-to-pdf/input-quarterly-report.docx"), "pdf", store_file: true)
    file = result.file
    assert file.stored?
    assert_match(/\A[0-9a-f]{32}\z/, file.file_id)
    # Never follow a link to another host from a live test (it could be the production API).
    assert_equal URI(@base_url).host, URI(file.url).host, "the stored file's link points to another host"
    assert_equal URI(@base_url).port, URI(file.url).port, "the stored file's link points to another port"
    assert_raises(PdfConversionApi::StoredFileError) { file.data }

    data = file.download
    assert_equal file.size, data.bytesize
    assert data.start_with?("%PDF-")
    Dir.mktmpdir do |dir|
      path = file.save(dir)
      assert_equal data, File.binread(path)
    end

    assert_equal true, @client.delete_stored_file(file.file_id)
    assert_equal false, @client.delete_stored_file(file.file_id)
    assert_raises(PdfConversionApi::NotFoundError) { file.download }
  end

  def test_unsupported_pair_is_404
    error = assert_raises(PdfConversionApi::NotFoundError) do
      @client.convert_file(sample("docx-to-pdf/input-quarterly-report.docx"), "dwg")
    end
    assert_equal 404, error.status
    assert_equal "conversion from docx to dwg is not supported", error.message
    refute_empty error.request_id.to_s
  end

  def test_wrong_key_is_401
    client = PdfConversionApi::Client.new(api_key: "wrong-key-0000000000000000", base_url: @base_url)
    error = assert_raises(PdfConversionApi::AuthenticationError) do
      client.convert_file(sample("docx-to-pdf/input-quarterly-report.docx"), "pdf")
    end
    assert_equal 401, error.status
    assert_includes error.message, "valid API key"
  end

  def test_bad_page_range_is_400
    error = assert_raises(PdfConversionApi::BadRequestError) do
      @client.convert_file(sample("pdf-to-jpg/input-season-guide.pdf"), "jpg", params: { PageRange: "3-1" })
    end
    assert_equal "PageRange '3-1' is not valid (example: 1-3,5)", error.message
  end

  def test_unicode_and_quote_in_file_name
    upload = PdfConversionApi::UploadFile.from_bytes("hello\n", "Résumé \"final\".txt")
    result = @client.convert("txt", "pdf", upload)
    assert_equal "Résumé _final_.pdf", result.file.name
  end

  def test_conversions
    list = @client.conversions
    assert_operator list.length, :>, 100
    docx = list.find { |c| c.from == "docx" && c.to == "pdf" }
    refute_nil docx
    assert_equal "DOCX to PDF", docx.title
    assert_equal "one", docx.inputs
  end

  def test_qrcode_without_files
    result = @client.convert("data", "qrcode", params: { Data: "https://pdfconversionapi.com" })
    assert_equal "qrcode.svg", result.file.name
    assert_includes result.file.data, "<svg"
  end
end
