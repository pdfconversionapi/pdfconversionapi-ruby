# frozen_string_literal: true

require_relative "test_helper"
require "securerandom"
require "time"

# Runs every case in ../conformance/cases.json against ../conformance/mock-server.mjs.
# The format is described in ../conformance/README.md.
class ConformanceTest < Minitest::Test
  SUITE = JSON.parse(File.read(File.join(TestSupport::CONFORMANCE_DIR, "cases.json"), encoding: "UTF-8"))
  CASES = SUITE.fetch("cases")
  RUN_ID = SecureRandom.hex(4)

  CASES.each do |kase|
    define_method("test_#{kase.fetch('id').tr('-', '_')}") { run_case(kase) }
  end

  def test_every_case_has_a_test
    assert_operator CASES.length, :>=, 47
    assert_equal CASES.length, CASES.map { |c| c["id"] }.uniq.length
  end

  private

  # ---- running a case ------------------------------------------------------------------------

  def run_case(kase)
    expect = kase.fetch("expect")
    sleeps = []
    client_options = kase.fetch("client", {})
    mock_id = "#{kase['id']}-#{RUN_ID}-#{SecureRandom.hex(3)}" if %w[convert stored_file_flow].include?(kase["call"])

    outcome = nil
    with_client(client_options, sleeps) do |client|
      outcome =
        begin
          [:ok, perform(client, kase, mock_id)]
        rescue StandardError => e
          [:error, e]
        end
    end

    if expect.key?("error")
      assert_equal :error, outcome[0], "expected #{expect['error']['type']}, got a result"
      check_error(expect["error"], outcome[1])
    else
      raise outcome[1] if outcome[0] == :error

      check_value(kase, expect, outcome[1])
    end
    assert_equal expect["attempts"], TestSupport::Mock.attempts(mock_id), "attempts" if expect.key?("attempts")
    check_sleeps(expect["min_sleeps"], sleeps) if expect.key?("min_sleeps")
  end

  def with_client(options, sleeps, &block)
    args = {
      base_url: TestSupport::Mock.url + options.fetch("base_url_suffix", ""),
      sleeper: ->(seconds) { sleeps << seconds }
    }
    args[:max_retries] = options["max_retries"] if options.key?("max_retries")
    args[:timeout] = options["timeout_seconds"] if options.key?("timeout_seconds")
    key = options.key?("api_key") ? options["api_key"] : SUITE.fetch("key")
    # A null key means no key at all: PDFCONVERSIONAPI_KEY must not supply one.
    TestSupport.with_env("PDFCONVERSIONAPI_KEY" => nil) do
      block.call(PdfConversionApi::Client.new(api_key: key, **args))
    end
  end

  def perform(client, kase, mock_id)
    case kase.fetch("call")
    when "convert" then convert(client, kase, mock_id)
    when "stored_file_flow" then stored_file_flow(client, kase, mock_id)
    when "usage" then client.usage
    when "conversions" then client.conversions
    when "delete_stored_file" then client.delete_stored_file(kase.fetch("file_id"))
    else flunk "unknown call #{kase['call']}"
    end
  end

  def convert(client, kase, mock_id)
    params = kase.fetch("params", {}).to_h { |name, value| [name, value.is_a?(Hash) ? named_input(value) : value] }
    params["MockId"] = mock_id
    options = kase.fetch("options", {})
    keywords = { params: params, file_name: options["file_name"], store_file: options["store_file"] }
    # No "files" key: call without the argument at all.
    return client.convert(kase.fetch("from"), kase.fetch("to"), **keywords) unless kase.key?("files")

    descriptors = kase["files"]
    files = descriptors.map { |d| input(d) }
    files = files.first if descriptors.length == 1
    client.convert(kase.fetch("from"), kase.fetch("to"), files, **keywords)
  end

  # An input descriptor as the SDK takes it.
  def input(descriptor)
    if descriptor.key?("path")
      TestSupport.fixture(descriptor["path"]) # a String is a path
    elsif descriptor.key?("bytes")
      PdfConversionApi::UploadFile.from_bytes(File.binread(TestSupport.fixture(descriptor["bytes"])), descriptor["name"])
    elsif descriptor.key?("stream")
      File.open(TestSupport.fixture(descriptor["stream"]), "rb") do |io|
        PdfConversionApi::UploadFile.from_io(io, descriptor["name"])
      end
    elsif descriptor.key?("bytes_utf8")
      PdfConversionApi::UploadFile.from_bytes(descriptor["bytes_utf8"].encode(Encoding::UTF_8).b, descriptor["name"])
    else
      flunk "unknown input descriptor #{descriptor.inspect}"
    end
  end

  # A descriptor as a parameter value: a path must be a Pathname there (a String is text).
  def named_input(descriptor)
    descriptor.key?("path") ? Pathname(TestSupport.fixture(descriptor["path"])) : input(descriptor)
  end

  def stored_file_flow(client, kase, mock_id)
    expect = kase.fetch("expect")
    result = convert(client, kase, mock_id)
    check_result(expect["result"], result) if expect.key?("result")
    file = result.file
    assert_raises(error_class(expect.fetch("data_access_error"))) { file.data }
    assert_equal File.binread(TestSupport.fixture(expect.fetch("download_fixture"))), file.download
    assert_equal expect.fetch("first_delete"), client.delete_stored_file(file.file_id)
    assert_equal expect.fetch("second_delete"), client.delete_stored_file(file.file_id)
    assert_raises(error_class(expect.fetch("download_after_delete_error"))) { file.download }
    :flow_checked
  end

  # ---- expectations --------------------------------------------------------------------------

  def check_value(kase, expect, value)
    return if kase["call"] == "stored_file_flow" # checked inside the flow

    check_result(expect["result"], value) if expect.key?("result")
    check_echo(expect["echo"], value) if expect.key?("echo")
    check_save_all(expect["save_all"], value) if expect.key?("save_all")
    check_conversions(expect["conversions"], value) if expect.key?("conversions")
    check_usage(expect["usage"], value) if expect.key?("usage")
    assert_equal expect["deleted"], value, "deleted" if expect.key?("deleted")
  end

  def check_result(expected, result)
    assert_instance_of PdfConversionApi::ConversionResult, result
    assert_equal expected["conversion_cost"], result.conversion_cost if expected.key?("conversion_cost")
    if expected["request_id"] == true
      assert_kind_of String, result.request_id
      refute_empty result.request_id
    end
    return unless expected.key?("files")

    assert_equal expected["files"].length, result.files.length, "number of files"
    expected["files"].zip(result.files).each do |want, file|
      assert_equal want["name"], file.name if want.key?("name")
      assert_equal want["ext"], file.ext if want.key?("ext")
      assert_equal want["size"], file.size if want.key?("size")
      assert_equal File.binread(TestSupport.fixture(want["data_fixture"])), file.data if want.key?("data_fixture")
      assert_equal want["data_utf8"].b, file.data if want.key?("data_utf8")
      next unless want["stored"] == true

      assert file.stored?
      refute_nil file.url
      refute_nil file.file_id
      assert_raises(PdfConversionApi::StoredFileError) { file.data }
    end
  end

  def check_echo(expected, result)
    echo = JSON.parse(result.file.download)
    headers = echo.fetch("headers")
    assert_equal expected["method"], echo["method"] if expected.key?("method")
    assert_equal expected["path"], echo["path"] if expected.key?("path")
    assert_equal expected["query"], echo["query"] if expected.key?("query")
    assert_equal expected["authorization"], headers["authorization"] if expected.key?("authorization")
    if expected.key?("user_agent_prefix")
      assert headers["user-agent"].to_s.start_with?(expected["user_agent_prefix"]), headers["user-agent"]
    end
    if expected.key?("content_type_prefix")
      assert headers["content-type"].to_s.start_with?(expected["content_type_prefix"]), headers["content-type"]
    end
    check_fields(expected["fields"], echo.fetch("fields")) if expected.key?("fields")
    (expected["absent_fields"] || []).each do |name|
      refute(echo["fields"].any? { |f| f["name"] == name }, "field #{name} should be absent")
    end
  end

  # Each expected field appears, matching every key given, in that relative order.
  def check_fields(expected, actual)
    position = 0
    expected.each do |want|
      found = (position...actual.length).find { |i| want.all? { |k, v| actual[i][k] == v } }
      refute_nil found, "field #{want.inspect} not found in order in #{actual.inspect}"
      position = found + 1
    end
  end

  def check_save_all(expected, result)
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out")
      result.save_all(out)
      assert_equal expected.keys.sort, Dir.children(out).sort
      expected.each { |name, text| assert_equal text.b, File.binread(File.join(out, name)) }
    end
  end

  def check_conversions(expected, list)
    assert_equal expected["count"], list.length
    expected.fetch("first", {}).each { |field, value| assert_equal value, list.first.public_send(field), field }
  end

  def check_usage(expected, usage)
    expected.each do |field, value|
      actual = usage.public_send(field)
      if field.start_with?("period_")
        assert_equal Time.iso8601(value), actual, field
      else
        assert_equal value, actual, field
      end
    end
  end

  def check_error(expected, error)
    assert_kind_of error_class(expected.fetch("type")), error, "#{error.class}: #{error.message}"
    assert_equal expected["status"], error.status if expected.key?("status")
    assert_equal expected["message"], error.message if expected.key?("message")
    assert_includes error.message, expected["message_contains"] if expected.key?("message_contains")
    assert_equal expected["retry_after"], error.retry_after if expected.key?("retry_after")
    case expected["request_id"]
    when true
      assert_kind_of String, error.request_id
      refute_empty error.request_id
    when false
      assert_nil error.request_id
    end
  end

  def check_sleeps(minimums, sleeps)
    assert_equal minimums.length, sleeps.length, "number of waits: #{sleeps.inspect}"
    minimums.zip(sleeps).each { |min, slept| assert_operator slept, :>=, min }
  end

  def error_class(name)
    name == "ArgumentError" ? ::ArgumentError : PdfConversionApi.const_get(name)
  end
end
