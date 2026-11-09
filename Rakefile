# frozen_string_literal: true

require "rake/testtask"

# Unit tests: no network, no Node.js.
Rake::TestTask.new("test:unit") do |t|
  t.libs = %w[lib test]
  t.test_files = FileList["test/unit/*_test.rb"]
  t.warning = true
end

# The shared conformance cases against the mock API (needs Node.js 18+).
Rake::TestTask.new("test:conformance") do |t|
  t.libs = %w[lib test]
  t.test_files = FileList["test/conformance_test.rb"]
  t.warning = true
end

# Live tests against the real API: ../conformance/.local-api.env, else PDFCONVERSIONAPI_LIVE_BASE_URL
# and PDFCONVERSIONAPI_KEY from the environment; skipped without either.
Rake::TestTask.new("test:live") do |t|
  t.libs = %w[lib test]
  t.test_files = FileList["test/live_test.rb"]
  t.warning = true
end

desc "Run the unit and conformance tests"
task test: %w[test:unit test:conformance]

desc "Check every Ruby file's syntax; any warning fails"
task :lint do
  require "open3"
  files = FileList["lib/**/*.rb", "test/**/*.rb", "examples/**/*.rb", "script/**/*.rb", "Rakefile", "*.gemspec"]
  problems = files.filter_map do |file|
    out, err, status = Open3.capture3(RbConfig.ruby, "-wc", file)
    "#{file}: #{err}#{out unless out.strip == 'Syntax OK'}" unless status.success? && err.empty?
  end
  abort(problems.join("\n")) unless problems.empty?
  puts "#{files.length} files: syntax OK, no warnings"
end

desc "Validate the RBS type signatures in sig/"
task :rbs do
  sh "rbs -r stringio -I sig validate"
end

desc "Run the conformance cases with every call type-checked against sig/ (needs the rbs gem)"
task "test:types" do
  env = {
    "RBS_TEST_TARGET" => "PdfConversionApi::*",
    "RBS_TEST_OPT" => "-r stringio -I sig",
    "RBS_TEST_LOGLEVEL" => "error",
    "RBS_TEST_RAISE" => "true"
  }
  sh env, RbConfig.ruby, "-rrbs/test/setup", "-Ilib", "-Itest", "test/conformance_test.rb"
end

desc "Run the examples and the README's snippets against the local API (../conformance/.local-api.env)"
task :examples do
  sh RbConfig.ruby, "script/run_examples.rb", "examples"
  sh RbConfig.ruby, "script/run_examples.rb", "readme"
end

desc "Build the gem into pkg/ (nothing is published)"
task :build do
  version = File.read("lib/pdfconversionapi/version.rb")[/VERSION = "([^"]+)"/, 1]
  mkdir_p "pkg"
  sh "gem build pdfconversionapi.gemspec --output pkg/pdfconversionapi-#{version}.gem"
end

task default: %w[lint test]
