# frozen_string_literal: true

require_relative "scripted_client"

class ParamsTest < Minitest::Test
  include FormParsing

  OK = ScriptedClient::OK

  def hello
    TestSupport.fixture("hello.txt")
  end

  def fields_for(files = hello, **options)
    client = ScriptedClient.new([OK])
    client.convert("txt", "pdf", files, **options)
    sent_fields(client)
  end

  def text_fields(fields)
    fields.reject { |f| f[:filename] }.map { |f| [f[:name], f[:data]] }
  end

  def test_values_as_text
    params = {
      "S" => "1-3", "I" => 72, "N" => -5, "F" => 1.5, "W" => 72.0, "Tiny" => 1.0e-5, "Neg" => -2.5e-7,
      "Big" => 1e20, "R" => Rational(1, 2), "T" => true, "No" => false, Sym: :landscape, "Nil" => nil
    }
    assert_equal [%w[S 1-3], %w[I 72], %w[N -5], %w[F 1.5], %w[W 72], %w[Tiny 0.00001], %w[Neg -0.00000025],
                  %w[Big 100000000000000000000], %w[R 0.5], %w[T true], %w[No false], %w[Sym landscape]],
                 text_fields(fields_for(params: params))
  end

  def test_unusable_values
    client = ScriptedClient.new
    [Float::NAN, Float::INFINITY, Object.new, [1], { a: 1 }].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { client.convert("txt", "pdf", hello, params: { "X" => bad }) }
    end
    assert_empty client.sent
  end

  def test_one_file_is_file_several_are_files
    assert_equal [%w[File hello.txt]], fields_for.map { |f| [f[:name], f[:filename]] }
    assert_equal [%w[File hello.txt]], fields_for([hello]).map { |f| [f[:name], f[:filename]] }
    files = [TestSupport.fixture("a.txt"), TestSupport.fixture("b.txt"), TestSupport.fixture("c.txt")]
    assert_equal [%w[Files a.txt], %w[Files b.txt], %w[Files c.txt]],
                 fields_for(files).map { |f| [f[:name], f[:filename]] }
    assert_equal ["A\n", "B\n", "C\n"], fields_for(files).map { |f| f[:data] }
  end

  def test_files_come_first_then_parameters_in_order
    fields = fields_for(params: { "B" => "1", "A" => "2" })
    assert_equal %w[File B A], fields.map { |f| f[:name] }
  end

  def test_named_files
    logo = TestSupport.fixture("logo.png")
    fields = fields_for(params: {
                          "ImageFile" => Pathname(logo),
                          "OverlayFile" => PdfConversionApi::UploadFile.from_bytes("%PDF", "overlay.pdf"),
                          "Other" => StringIO.new("io"),
                          "Opacity" => 30
                        })
    assert_equal [["File", "hello.txt"], ["ImageFile", "logo.png"], ["OverlayFile", "overlay.pdf"],
                  ["Other", "file"], ["Opacity", nil]],
                 fields.map { |f| [f[:name], f[:filename]] }
    assert_equal File.binread(logo), fields[1][:data]
  end

  def test_a_string_value_is_text_not_a_path
    fields = fields_for(params: { "Text" => hello })
    assert_equal [["Text", hello]], text_fields(fields)
  end

  def test_typed_options
    fields = fields_for(file_name: "custom name", store_file: true)
    assert_equal [["FileName", "custom name"], %w[StoreFile true]], text_fields(fields)
  end

  def test_typed_options_win_over_params
    fields = fields_for(params: { "filename" => "from params", "STOREFILE" => "false", "X" => "1" },
                        file_name: "typed", store_file: true)
    assert_equal [%w[X 1], %w[FileName typed], %w[StoreFile true]], text_fields(fields)
  end

  def test_store_file_false_sends_nothing
    assert_equal [], text_fields(fields_for(store_file: false))
    assert_equal [], text_fields(fields_for(params: { "StoreFile" => true }, store_file: false))
    assert_equal [%w[StoreFile true]], text_fields(fields_for(params: { "StoreFile" => true }))
  end

  def test_unicode_file_name_is_raw_utf8
    upload = PdfConversionApi::UploadFile.from_bytes("unicode\n", "Résumé final (1).txt")
    assert_equal "Résumé final (1).txt", fields_for(upload).first[:filename]
  end
end
