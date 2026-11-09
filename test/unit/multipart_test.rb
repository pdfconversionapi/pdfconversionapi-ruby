# frozen_string_literal: true

require_relative "../test_helper"

class MultipartTest < Minitest::Test
  Multipart = PdfConversionApi::Multipart
  UploadFile = PdfConversionApi::UploadFile

  def test_exact_body
    form = Multipart.new(boundary: "XyZ")
    form.add_file("File", UploadFile.from_bytes("hello", "a.txt"))
    form.add_text("PageRange", "1-3")
    expected = "--XyZ\r\n" \
               "Content-Disposition: form-data; name=\"File\"; filename=\"a.txt\"\r\n" \
               "Content-Type: application/octet-stream\r\n" \
               "\r\n" \
               "hello\r\n" \
               "--XyZ\r\n" \
               "Content-Disposition: form-data; name=\"PageRange\"\r\n" \
               "\r\n" \
               "1-3\r\n" \
               "--XyZ--\r\n"
    assert_equal expected.b, form.to_s
    assert_equal "multipart/form-data; boundary=XyZ", form.content_type
  end

  def test_file_name_is_raw_utf8_with_quote_cr_lf_as_underscores
    form = Multipart.new(boundary: "b")
    form.add_file("File", UploadFile.from_bytes("x", "Résumé \"final\"\r\n(1).txt"))
    body = form.to_s
    assert_includes body, "filename=\"R\xC3\xA9sum\xC3\xA9 _final___(1).txt\"".b
    refute_includes body, "filename*".b
    refute_includes body, "=?utf-8?".b
    refute_includes body, "%".b
  end

  def test_field_names_keep_quote_cr_lf_as_percent_escapes
    form = Multipart.new(boundary: "b")
    form.add_text("Page\"Range\r\nX", "1-3")
    form.add_file("Image\"File", UploadFile.from_bytes("x", "a\"b.png"))
    body = form.to_s
    assert_includes body, "name=\"Page%22Range%0D%0AX\"\r\n\r\n1-3\r\n".b
    assert_includes body, "name=\"Image%22File\"; filename=\"a_b.png\"".b
  end

  def test_text_values_are_utf8
    form = Multipart.new(boundary: "b")
    form.add_text("Text", "Brouillon — été".encode(Encoding::UTF_16LE))
    assert_includes form.to_s, "Brouillon \xE2\x80\x94 \xC3\xA9t\xC3\xA9".b
  end

  def test_boundary_is_random
    refute_equal Multipart.new.boundary, Multipart.new.boundary
    assert_match(/\Apdfconversionapi-[0-9a-f]{32}\z/, Multipart.new.boundary)
  end

  def test_stream_length_and_reads
    form = Multipart.new
    form.add_file("File", UploadFile.from_path(TestSupport.fixture("hello.txt")))
    form.add_text("A", "1")
    whole = form.to_s
    stream, length = form.stream
    assert_equal whole.bytesize, length

    chunks = []
    while (chunk = stream.read(7))
      assert_operator chunk.bytesize, :<=, 7
      chunks << chunk
    end
    assert_equal whole, chunks.join
    assert_nil stream.read(7)
    assert_equal "", stream.read
    stream.close
  end

  def test_stream_works_with_copy_stream
    form = Multipart.new
    form.add_file("File", UploadFile.from_path(TestSupport.fixture("logo.png")))
    stream, = form.stream
    out = StringIO.new(+"".b)
    IO.copy_stream(stream, out)
    assert_equal form.to_s, out.string
  ensure
    stream&.close
  end

  def test_path_is_read_again_for_each_stream
    Dir.mktmpdir do |dir|
      path = File.join(dir, "in.txt")
      File.binwrite(path, "first")
      form = Multipart.new(boundary: "b")
      form.add_file("File", UploadFile.from_path(path))
      assert_includes form.to_s, "first"
      File.binwrite(path, "second, longer")
      stream, length = form.stream
      body = stream.read
      stream.close
      assert_includes body, "second, longer"
      assert_equal body.bytesize, length
    end
  end
end
