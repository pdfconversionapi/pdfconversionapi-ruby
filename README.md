# PDF Conversion API for Ruby

The official Ruby client for the [PDF Conversion API](https://pdfconversionapi.com/docs). It
converts documents, spreadsheets, presentations, images and PDFs, and it merges, splits,
compresses and watermarks PDFs. Each call is one request and returns typed results or raises
typed errors. Retries follow the API's rules.

- Docs: https://pdfconversionapi.com/docs
- Get an API key: https://app.pdfconversionapi.com
- Plans and limits: https://pdfconversionapi.com/pricing

Ruby 3.0 or later. Only Ruby's standard library is used; the gem has no dependencies.

## Install

```bash
gem install pdfconversionapi
```

Or in your Gemfile:

```ruby
# Gemfile
gem "pdfconversionapi"
```

## The API key

Sign in at https://app.pdfconversionapi.com to get a free key, then put it in the
`PDFCONVERSIONAPI_KEY` environment variable, which the client reads by default:

```bash
export PDFCONVERSIONAPI_KEY="paste-your-key-here"
```

Keep it on your server. The client sends the key only in the `Authorization` header of API
calls. It never appears in URLs, error messages or `inspect` output, and it is never sent with
the download links of stored files.

## Quick start

```ruby
require "pdfconversionapi"

client = PdfConversionApi::Client.new # reads PDFCONVERSIONAPI_KEY
result = client.convert_file("report.docx", "pdf")
result.save_all("out") # writes out/report.pdf
```

`convert_file` reads the input format from the file's extension. `save_all` creates the folder
if needed, writes every output under its own name, and returns the paths written.

## Convert one file

`convert(from, to, files)` names both formats. The input can be:

- a **path**, as a `String` or a `Pathname`. **A string is always a path**, never file content;
- an open **IO**: a `File`, `StringIO`, `Tempfile` or anything with `#read`;
- **bytes** in memory, via `PdfConversionApi::UploadFile.from_bytes(data, name)`.

```ruby
require "stringio"

pdf = client.convert("docx", "pdf", "report.docx").file
puts "#{pdf.name} #{pdf.size} bytes" # report.pdf 82830 bytes

File.open("report.docx", "rb") { |io| client.convert("docx", "pdf", io) }

bytes = File.binread("report.docx")
upload = PdfConversionApi::UploadFile.from_bytes(bytes, "q3-report.docx")
puts client.convert("docx", "pdf", upload).file.name # q3-report.pdf
```

The name sent with the file becomes the output's name, with the new extension. Only the file's
own name is sent, never its folders. Bytes or an IO without a name are sent as `file`. Use
`UploadFile.from_io(io, "name.docx")` to name an IO, or `UploadFile.from_path(path, "name.docx")`
to send a file under another name.

An output file has `name`, `ext`, `size` and `data` (its bytes, as a binary `String`).
`save(path)` writes it and returns the path. If `path` is a folder, the file goes inside it
under its own name.

## Several outputs: PDF to JPG

Conversions that work page by page return one file per page, in order:

```ruby
result = client.convert_file("guide.pdf", "jpg", params: { ImageResolution: 72 })
result.files.each { |file| puts "#{file.name} #{file.size} bytes" }
result.save_all("pages")
```

```text
guide-1.jpg 65272 bytes
guide-2.jpg 66627 bytes
```

`result.file` is the first output. `result.files` holds them all, and the result is
`Enumerable` over them. `result.conversion_cost` (always 1), `result.conversion_time` (seconds
on the server) and `result.request_id` describe the request.

## Several inputs: merge

Pass a list. One file is sent as `File`, and two or more as repeated `Files` fields, in the
order given:

```ruby
result = client.convert("pdf", "merge", ["invoice.pdf", "terms.pdf", "timesheet.pdf"],
                        file_name: "october-billing")
puts result.file.save(".") # ./october-billing.pdf
```

`pdf/to/merge`, `images/to/pdf`, `images/to/join` and `file/to/zip` take several files. The
others answer `400 this conversion takes exactly one file`.

## A second file: image watermark

Some tools take a second file in a field of its own, such as `ImageFile` for
`pdf/to/image-watermark` or `OverlayFile` for `pdf/to/pdf-watermark`. Pass it as a parameter
whose value is a `Pathname`, an IO or an `UploadFile`. A plain `String` parameter is sent as
text, never read as a path:

```ruby
require "pathname"

result = client.convert_file("invoice.pdf", "image-watermark",
                             params: { ImageFile: Pathname("logo.png"), Opacity: 30 },
                             file_name: "invoice-stamped")
puts result.file.save(".") # ./invoice-stamped.pdf
```

## Parameters

`params:` is a hash of parameter name to value. Each conversion's page in the docs lists the
names it reads, for example [PDF to JPG](https://pdfconversionapi.com/convert/pdf-to-jpg).

- Strings and Symbols are sent as they are, numbers in plain decimal (`72`, `1.5`), and
  booleans as `true` or `false`.
- A `nil` value is left out.
- A `Pathname`, IO or `UploadFile` is sent as a file field with that name.
- Names can be Strings or Symbols. The API reads them case-insensitively.

Two options have their own keywords: `file_name:` (the output's name without extension, sent
as `FileName`) and `store_file:` (sent as `StoreFile=true`). They win over the same names in
`params:`.

```ruby
result = client.convert_file("guide.pdf", "jpg",
                             params: { PageRange: "2", ImageResolution: 72, Grayscale: true },
                             file_name: "cover")
puts result.files.map(&:name).inspect # ["cover-2.jpg"]
```

## Conversions that take no file

A few conversions, such as `data/to/qrcode`, read only parameters. Leave the files out:

```ruby
result = client.convert("data", "qrcode", params: { Data: "https://pdfconversionapi.com" })
puts result.file.name # qrcode.svg
```

Without files, a conversion that needs one answers `400 no input file was provided`.

## Stored files: download and delete

With `store_file: true` the API keeps each output and returns a download link instead of its
data. The link works for 3 hours and needs no API key. Read the file with `download` (bytes) or
`download_to`/`save` (streamed to disk). Delete it early with `delete_stored_file`:

```ruby
result = client.convert_file("report.docx", "pdf", store_file: true)
file = result.file
puts file.stored?  # true
puts file.file_id  # 32 hex characters

path = file.download_to("report.pdf") # streamed to disk; no API key is sent
puts File.size(path) == file.size     # true

puts client.delete_stored_file(file.file_id) # true: deleted
puts client.delete_stored_file(file.file_id) # false: nothing left to delete
```

Reading `file.data` of a stored file raises `PdfConversionApi::StoredFileError`.
`client.download(url)` and `client.download_to(url, path)` work on a link you kept from earlier.
Anyone with the link can download the file until it expires or you delete it, so treat it like
a password.

## Usage

```ruby
usage = client.usage
puts "#{usage.plan}: #{usage.used} of #{usage.included} used, #{usage.remaining} left"
puts usage.period_end # 2026-12-01 00:00:00 UTC
```

`Usage` also has `overage`, `running`, `concurrent_limit` and `max_upload_mb`. `period_start`
and `period_end` are UTC `Time`s. The call doesn't use a conversion.

## The list of conversions

`conversions` lists every conversion the API offers. It needs no API key:

```ruby
conversions = client.conversions
puts conversions.length # 556
docx = conversions.select { |c| c.from == "docx" }.map(&:to)
puts docx.join(" ") # docx html jpg md odt pdf png protect rtf tiff txt webp xml
```

Each `Conversion` has `from`, `to`, `title`, `category` and `inputs` (`"one"`, `"many"` or
`"optional"`).

## Errors

Every error the gem raises is a `PdfConversionApi::Error`, and bad arguments raise
`ArgumentError`. An error status from the API raises a subclass of `PdfConversionApi::ApiError`:

| Class | Status | |
|---|---|---|
| `BadRequestError` | 400 | A parameter, page range or number of files is wrong |
| `AuthenticationError` | 401 | The key is missing, unknown or replaced |
| `PermissionDeniedError` | 403 | The key's plan isn't set up |
| `NotFoundError` | 404 | Unsupported conversion, or a stored file that expired or was deleted |
| `PayloadTooLargeError` | 413 | The request or an image is over a limit |
| `UnprocessableEntityError` | 422 | The file can't be read or converted as asked |
| `RateLimitError` | 429 | Too many requests or conversions at once, or the month is used up |
| `InternalServerError` | 500 | An unexpected failure on the server |
| `ServiceUnavailableError` | 503 | The servers are busy, or conversions on the plan are paused |
| `GatewayTimeoutError` | 504 | The conversion ran out of time |

Any other status raises `ApiError` itself. Each one has `status`, `message` (the API's own
text), `request_id` (quote it when you write to support), `retry_after` (seconds, on 429 and
503) and `body` (the raw response). `to_s` adds the status and the request id:

```ruby
begin
  client.convert_file("report.docx", "dwg")
rescue PdfConversionApi::NotFoundError => e
  puts e.status  # 404
  puts e.message # conversion from docx to dwg is not supported
  puts e         # HTTP 404: conversion from docx to dwg is not supported (request id: ...)
end
```

The other errors:

| Class | When |
|---|---|
| `MissingApiKeyError` | A call that needs a key was made without one. Raised before anything is sent. |
| `StoredFileError` | `data` of a stored file was read: use `download`. |
| `ConnectionError` | No response after every retry, or the connection dropped while the response was being read. |
| `TimeoutError` | The client's own timeout ran out. |
| `InvalidResponseError` | A 200 whose body can't be used (bad JSON, or data that doesn't match `FileSize`). |

A typical handler:

```ruby
begin
  result = client.convert_file("report.docx", "pdf")
  result.save_all("out")
rescue PdfConversionApi::RateLimitError, PdfConversionApi::ServiceUnavailableError => e
  warn "try again in #{e.retry_after} seconds: #{e.message}"
rescue PdfConversionApi::ApiError => e
  warn "the API refused the request: #{e}"
rescue PdfConversionApi::Error => e
  warn "no usable answer: #{e.message}"
end
```

## Retries

Every call, downloads included, retries what the API says is worth retrying, up to
`max_retries` (4) more times:

- **429 and 503** are retried after the `Retry-After` seconds plus a random delay (jitter).
  A `Retry-After` above `max_retry_wait` (60 seconds), such as a used-up month or paused
  conversions, is raised at once with `retry_after` set.
- **A 500** is retried once, after 1 second plus the random delay.
- **No response** (refused or reset connection, DNS failure, connect timeout) is retried with
  the random delay alone. That delay can be up to 2, 4, 8 and then 16 seconds.
- **400, 401, 403, 404, 413, 422 and 504** are never retried.
- **The client's own timeout** is never retried. A conversion that is still running on the server
  counts toward the month if it succeeds, so a quick retry would run it twice. A connection that
  drops after the response has started is not retried either, for the same reason.

```ruby
client = PdfConversionApi::Client.new(max_retries: 0)       # one attempt only
client = PdfConversionApi::Client.new(max_retry_wait: 600)  # wait out paused conversions too
```

## Timeouts

By default each attempt has 240 seconds, from sending the request to reading the whole response,
and 10 seconds to connect. That leaves room for the API's 120 seconds of conversion, a wait for
a free slot, and your upload and download. Raise it for large files or slow links, for every
call or for one:

```ruby
client = PdfConversionApi::Client.new(timeout: 600, connect_timeout: 20)
result = client.convert_file("report.docx", "pdf", timeout: 900)
```

## Large files

The whole response is held in memory while it is decoded, and base64 makes it a third larger
than the files it holds: a 100 MB result arrives as about 133 MB of JSON. For large outputs, ask
for a stored file and stream it to disk:

```ruby
result = client.convert_file("report.docx", "pdf", store_file: true)
result.save_all("out") # downloads each stored file straight to disk
result.each { |file| client.delete_stored_file(file.file_id) }
```

Uploads given as paths are streamed from disk. Bytes and IOs are held in memory, and an IO is
read once, before the first attempt, so every retry sends the same bytes.

## Configuration

| Option | Default | |
|---|---|---|
| `api_key:` | `ENV["PDFCONVERSIONAPI_KEY"]` | May be missing: `conversions` and downloads work without a key. |
| `base_url:` | `ENV["PDFCONVERSIONAPI_BASE_URL"]`, else `https://api.pdfconversionapi.com` | A trailing slash is ignored. |
| `timeout:` | 240 | Seconds per attempt for the whole response. |
| `connect_timeout:` | 10 | Seconds to open the connection. |
| `max_retries:` | 4 | Retries after the first attempt; 0 turns them off. |
| `max_retry_wait:` | 60 | The longest `Retry-After`, in seconds, worth waiting for. |
| `sleeper:` | `Kernel#sleep` | For tests: called with the seconds to wait between attempts. |

```ruby
client = PdfConversionApi::Client.new(
  api_key: ENV.fetch("PDFCONVERSIONAPI_KEY"),
  base_url: ENV.fetch("PDFCONVERSIONAPI_BASE_URL", "https://api.pdfconversionapi.com"),
  timeout: 300,
  max_retries: 2
)
puts client.inspect # the key shows as [set], never its value
```

One client can be shared between threads: it keeps no state between requests. Proxies follow
`Net::HTTP`'s usual `http_proxy`/`https_proxy` environment variables, and TLS certificates are
always verified.

## Development

```bash
rake test:unit         # unit tests
rake test:conformance  # the shared cases against the mock API (needs Node.js 18+)
rake test:live         # against the real API (see below); about 6 conversions
rake lint              # syntax check with warnings
rake build             # builds pkg/pdfconversionapi-<version>.gem
```

The conformance tests start the mock themselves. To use a mock that is already running (for
example from a container without Node.js), set `PDFCONVERSIONAPI_MOCK_URL` to its address. The
shared suite is read from `PDFCONVERSIONAPI_CONFORMANCE_DIR`, else `../conformance`, else
`./conformance`.

The live tests call the real API with the files in `conformance/samples/`. They use the base URL
and key in `conformance/.local-api.env` when it exists, else `PDFCONVERSIONAPI_LIVE_BASE_URL` and
`PDFCONVERSIONAPI_KEY` from the environment, and skip without either (a key alone doesn't start
them).

## License

MIT. See [LICENSE](LICENSE).
