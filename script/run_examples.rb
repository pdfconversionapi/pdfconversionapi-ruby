# frozen_string_literal: true

# Runs the examples and the README's Ruby snippets against the API running locally, each in a
# new temporary folder holding sample inputs (report.docx, guide.pdf, invoice.pdf, terms.pdf,
# timesheet.pdf, logo.png).
#
#   ruby script/run_examples.rb examples   # every file in examples/
#   ruby script/run_examples.rb readme     # every ```ruby block in README.md
#
# The base URL and key come from ../conformance/.local-api.env and are passed to each program
# as PDFCONVERSIONAPI_BASE_URL and PDFCONVERSIONAPI_KEY; the key is never printed. Programs that
# call client.usage run against the mock instead (the local API doesn't serve /v2/usage).
# A README snippet without its own `client = ...` line gets the quick start's client.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CONFORMANCE = File.expand_path(ENV.fetch("PDFCONVERSIONAPI_CONFORMANCE_DIR", "../conformance"), ROOT)
SAMPLES = File.expand_path(ENV.fetch("PDFCONVERSIONAPI_SAMPLES_DIR", "../../site/public/samples"), ROOT)
INPUTS = {
  "report.docx" => "docx-to-pdf/input-quarterly-report.docx",
  "guide.pdf" => "pdf-to-jpg/input-season-guide.pdf",
  "invoice.pdf" => "merge/input-invoice.pdf",
  "terms.pdf" => "merge/input-terms.pdf",
  "timesheet.pdf" => "merge/input-timesheet.pdf",
  "logo.png" => "file-to-zip/input-campsite-map.png"
}.freeze

def local_env
  file = File.join(CONFORMANCE, ".local-api.env")
  abort "missing #{file}" unless File.exist?(file)
  values = File.readlines(file, chomp: true, encoding: "UTF-8")
               .reject { |line| line.strip.empty? || line.lstrip.start_with?("#") }
               .to_h { |line| line.split("=", 2).map(&:strip) }
  {
    "PDFCONVERSIONAPI_KEY" => values.fetch("PDFCONVERSIONAPI_LOCAL_KEY"),
    "PDFCONVERSIONAPI_BASE_URL" => values.fetch("PDFCONVERSIONAPI_LOCAL_BASE_URL")
  }
end

def with_mock
  io = IO.popen(["node", File.join(CONFORMANCE, "mock-server.mjs"), "--port", "0"])
  url = io.gets.to_s.split(" ", 2).last.to_s.strip
  yield("PDFCONVERSIONAPI_KEY" => "test-key", "PDFCONVERSIONAPI_BASE_URL" => url)
ensure
  if io
    Process.kill("TERM", io.pid)
    io.close
  end
end

def readme_snippets
  text = File.read(File.join(ROOT, "README.md"), encoding: "UTF-8")
  text.scan(/^```ruby\n(.*?)^```/m).map(&:first).reject { |code| code.start_with?("# Gemfile") }
end

def program(code)
  prelude = +""
  prelude << "require \"pdfconversionapi\"\n" unless code.include?('require "pdfconversionapi"')
  prelude << "client = PdfConversionApi::Client.new\n" unless code.match?(/^\s*client = /)
  prelude + code
end

def run(name, code, env)
  Dir.mktmpdir("pdfconversionapi-example") do |dir|
    INPUTS.each { |to, from| FileUtils.cp(File.join(SAMPLES, from), File.join(dir, to)) }
    path = File.join(dir, "program.rb")
    File.write(path, code)
    output, status = Open3.capture2e(env, RbConfig.ruby, "-W:no-experimental", "-I", File.join(ROOT, "lib"), path,
                                     chdir: dir)
    written = Dir.glob("**/*", base: dir).reject do |f|
      INPUTS.key?(f) || f == "program.rb" || File.directory?(File.join(dir, f))
    end
    puts "== #{name}: #{status.success? ? 'ok' : "FAILED (exit #{status.exitstatus})"}"
    puts output.gsub(env.fetch("PDFCONVERSIONAPI_KEY"), "[key]")
    puts "   files written: #{written.sort.map { |f| "#{f} (#{File.size(File.join(dir, f))} bytes)" }.join(', ')}"
    status.success?
  end
end

mode = ARGV.first || "examples"
abort "usage: ruby script/run_examples.rb examples|readme" unless %w[examples readme].include?(mode)

programs =
  if mode == "examples"
    Dir[File.join(ROOT, "examples", "*.rb")].sort.map { |f| [File.basename(f), File.read(f, encoding: "UTF-8")] }
  else
    readme_snippets.each_with_index.map { |code, i| ["README snippet #{i + 1}", program(code)] }
  end

on_mock, on_local = programs.partition { |_, code| code.include?("client.usage") }
failures = on_local.count { |name, code| !run(name, code, local_env) }
with_mock { |env| failures += on_mock.count { |name, code| !run("#{name} (mock)", code, env) } } unless on_mock.empty?
puts failures.zero? ? "all #{programs.length} ran" : "#{failures} of #{programs.length} failed"
exit(failures.zero? ? 0 : 1)
