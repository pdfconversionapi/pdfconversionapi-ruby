# frozen_string_literal: true

require_relative "scripted_client"

# Parsing a 200, results, and names on disk (SPEC section 7).
class ResultsTest < Minitest::Test
  OutputFile = PdfConversionApi::OutputFile

  def convert_with(body, client: nil)
    client ||= ScriptedClient.new([[200, { "x-request-id" => "r1" }, body]])
    client.convert("txt", "pdf", TestSupport.fixture("hello.txt"))
  end

  def entry(name, data, **extra)
    { "FileName" => name, "FileExt" => File.extname(name).delete_prefix("."), "FileSize" => data.bytesize,
      "FileData" => [data].pack("m0") }.merge(extra)
  end

  def body(*entries)
    JSON.generate("ConversionCost" => 1, "ConversionTime" => 0.036, "Files" => entries)
  end

  def stored_entry(name, size, id = "ab" * 16)
    { "FileName" => name, "FileExt" => "pdf", "FileSize" => size, "Url" => "http://api.test/v2/d/#{id}/#{name}",
      "FileId" => id }
  end

  def test_result_fields
    result = convert_with(body(entry("p-1.jpg", "\xFF\xD8one".b), entry("p-2.jpg", "two")))
    assert_equal 1, result.conversion_cost
    assert_in_delta 0.036, result.conversion_time
    assert_equal "r1", result.request_id
    assert_equal %w[p-1.jpg p-2.jpg], result.files.map(&:name)
    assert_equal %w[p-1.jpg p-2.jpg], result.map(&:name)
    assert_same result.files.first, result.file
    file = result.file
    assert_equal "jpg", file.ext
    assert_equal 5, file.size
    assert_equal "\xFF\xD8one".b, file.data
    assert_equal Encoding::BINARY, file.data.encoding
    assert_equal file.data, file.bytes
    refute file.stored?
    refute file.stored
    assert_nil file.url
    assert_nil file.file_id
    assert_equal file.data, file.download
  end

  def test_integer_conversion_time
    result = convert_with(JSON.generate("ConversionCost" => 1, "ConversionTime" => 2, "Files" => [entry("a.pdf", "x")]))
    assert_equal 2.0, result.conversion_time
    assert_kind_of Float, result.conversion_time
  end

  def test_unusable_bodies
    [
      "{not json",
      "[]",
      JSON.generate("Files" => "nope"),
      JSON.generate("ConversionCost" => 1),
      body("not an object"),
      body(entry("a.pdf", "x").merge("FileSize" => 2)),                    # size mismatch
      body(entry("a.pdf", "x").merge("FileData" => "not base64!")),
      body(entry("a.pdf", "abcd").merge("FileData" => "YWJjZA")),          # padding missing
      body(entry("a.pdf", "x").merge("FileData" => "eA==\n")),             # not on one line
      body(entry("a.pdf", "x").tap { |e| e.delete("FileName") }),
      body(entry("a.pdf", "x").merge("FileSize" => "1")),
      body(entry("a.pdf", "x").tap { |e| e.delete("FileData") }),          # neither data nor link
      body(stored_entry("a.pdf", 1).tap { |e| e.delete("FileId") })
    ].each do |text|
      assert_raises(PdfConversionApi::InvalidResponseError, text) { convert_with(text) }
    end
  end

  def test_stored_files
    result = convert_with(body(stored_entry("a.pdf", 4)))
    file = result.file
    assert file.stored?
    assert_equal "http://api.test/v2/d/#{'ab' * 16}/a.pdf", file.url
    assert_equal "ab" * 16, file.file_id
    error = assert_raises(PdfConversionApi::StoredFileError) { file.data }
    assert_match(/download/, error.message)
    assert_raises(PdfConversionApi::StoredFileError) { file.bytes }
  end

  def test_stored_file_download_goes_through_the_client_without_key
    client = ScriptedClient.new([[200, {}, body(stored_entry("a.pdf", 4))], [200, {}, "%PDF"]])
    file = convert_with(nil, client: client).file
    assert_equal "%PDF", file.download
    assert_equal [:get, file.url, nil], client.sent.last.to_a.first(3)
  end

  def test_save
    result = convert_with(body(entry("out.pdf", "data")))
    Dir.mktmpdir do |dir|
      assert_equal File.join(dir, "out.pdf"), result.file.save(dir)
      assert_equal "data", File.binread(File.join(dir, "out.pdf"))

      target = File.join(dir, "renamed.pdf")
      File.binwrite(target, "old contents that are longer")
      assert_equal target, result.file.save(Pathname(target))
      assert_equal "data", File.binread(target)
      assert_equal target, result.file.download_to(target)
    end
  end

  def test_save_all
    result = convert_with(body(entry("a-1.png", "one"), entry("a-2.png", "two")))
    Dir.mktmpdir do |dir|
      out = File.join(dir, "new", "folder")
      paths = result.save_all(out)
      assert_equal [File.join(out, "a-1.png"), File.join(out, "a-2.png")], paths
      assert_equal %w[a-1.png a-2.png], Dir.children(out).sort
      assert_equal "two", File.binread(paths[1])
      File.binwrite(paths[0], "changed")
      result.save_all(Pathname(out))
      assert_equal "one", File.binread(paths[0])
    end
  end

  def test_names_on_disk
    assert_equal "passwd", OutputFile.safe_name("../../etc/passwd")
    assert_equal "b.pdf", OutputFile.safe_name("a\\b.pdf")
    assert_equal "Résumé final.pdf", OutputFile.safe_name("Résumé final.pdf")
    [".", "..", "", "dir/", "a/..", "x\\.", "nul\0.pdf"].each do |bad|
      assert_raises(PdfConversionApi::InvalidResponseError, bad.inspect) { OutputFile.safe_name(bad) }
    end
  end

  def test_save_all_never_leaves_the_folder
    result = convert_with(body(entry("../escape.pdf", "x"), entry("..", "y")))
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out")
      assert_raises(PdfConversionApi::InvalidResponseError) { result.save_all(out) }
      assert_equal ["escape.pdf"], Dir.children(out)
      refute File.exist?(File.join(dir, "escape.pdf"))
    end
  end

  def test_inspect_is_short
    result = convert_with(body(entry("a.pdf", "x" * 10_000)))
    assert_operator result.inspect.length, :<, 200
    assert_operator result.file.inspect.length, :<, 200
  end

  def test_conversion_equality
    a = PdfConversionApi::Conversion.new(from: "a", to: "b", title: "A to B", category: "C", inputs: "one")
    b = PdfConversionApi::Conversion.new(from: "a", to: "b", title: "A to B", category: "C", inputs: "one")
    assert_equal a, b
    assert_equal 1, [a, b].uniq.length
  end
end
