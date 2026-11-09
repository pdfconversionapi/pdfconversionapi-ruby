# frozen_string_literal: true

require_relative "../test_helper"

class UploadFileTest < Minitest::Test
  UploadFile = PdfConversionApi::UploadFile

  def test_from_path_sends_only_the_files_own_name
    upload = UploadFile.from_path(TestSupport.fixture("nested/inner.txt"))
    assert_equal "inner.txt", upload.name
    assert_equal 6, upload.size
    assert_equal TestSupport.fixture("nested/inner.txt"), upload.path
  end

  def test_from_path_accepts_pathname_and_a_name
    upload = UploadFile.from_path(Pathname(TestSupport.fixture("hello.txt")), "notes.txt")
    assert_equal "notes.txt", upload.name
  end

  def test_from_bytes
    assert_equal "file", UploadFile.from_bytes("abc").name
    assert_equal "a.pdf", UploadFile.from_bytes("abc", "a.pdf").name
    assert_equal 3, UploadFile.from_bytes("abc").size
    assert_raises(ArgumentError) { UploadFile.from_bytes(123) }
  end

  def test_names_lose_their_folders
    assert_equal "c.txt", UploadFile.from_bytes("", "a/b/c.txt").name
    assert_equal "b.txt", UploadFile.from_bytes("", "a\\b.txt").name
    assert_equal "My Photo (1).png", UploadFile.from_bytes("", "../../My Photo (1).png").name
    assert_equal "file", UploadFile.from_bytes("", "folder/").name
    assert_equal "file", UploadFile.from_bytes("", "").name
  end

  def test_names_are_utf8
    name = UploadFile.from_bytes("", "Résumé.txt".encode(Encoding::ISO_8859_1)).name
    assert_equal Encoding::UTF_8, name.encoding
    assert_equal "Résumé.txt", name
  end

  def test_from_io_reads_once_into_memory
    io = StringIO.new("stream data")
    upload = UploadFile.from_io(io, "s.txt")
    assert_equal "s.txt", upload.name
    assert_equal 11, upload.size
    assert io.eof?
    assert_equal "stream data", upload.open_io.read
    assert_equal "stream data", upload.open_io.read # the same bytes for every attempt
  end

  def test_from_io_names
    assert_equal "file", UploadFile.from_io(StringIO.new("x")).name
    File.open(TestSupport.fixture("hello.txt"), "rb") do |f|
      assert_equal "hello.txt", UploadFile.from_io(f).name
    end
    assert_equal UploadFile.method(:from_io), UploadFile.method(:from_stream)
    assert_raises(ArgumentError) { UploadFile.from_io(Object.new) }
  end

  def test_coerce
    assert_equal "hello.txt", UploadFile.coerce(TestSupport.fixture("hello.txt")).name
    assert_equal "hello.txt", UploadFile.coerce(Pathname(TestSupport.fixture("hello.txt"))).name
    assert_equal "file", UploadFile.coerce(StringIO.new("x")).name
    upload = UploadFile.from_bytes("x", "y.txt")
    assert_same upload, UploadFile.coerce(upload)
    error = assert_raises(ArgumentError) { UploadFile.coerce(42) }
    assert_match(/path .*IO.*UploadFile/, error.message)
  end

  def test_file_like_treats_strings_as_text
    refute UploadFile.file_like?("report.pdf")
    assert UploadFile.file_like?(Pathname("report.pdf"))
    assert UploadFile.file_like?(StringIO.new)
    assert UploadFile.file_like?(UploadFile.from_bytes("x"))
  end

  def test_frozen
    assert UploadFile.from_bytes("x").frozen?
  end
end
