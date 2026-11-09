# Changelog

## 0.1.0 (unreleased)

The first version.

- `PdfConversionApi::Client` with `convert`, `convert_file`, `usage`, `conversions`, `download`,
  `download_to` and `delete_stored_file`.
- Inputs from paths (`String` or `Pathname`), IOs, and bytes (`UploadFile.from_bytes`); named file
  fields such as `ImageFile`; conversions without files such as `data/to/qrcode`.
- Results with decoded data checked against `FileSize`, `save`/`save_all`, and stored files
  that are downloaded straight to disk.
- Typed errors for every status the API sends, with the API's message, the request id and
  `Retry-After`.
- Retries for 429 and 503 (after `Retry-After`), one retry for a 500, and backoff with jitter
  for failed connections. The client's own timeout is never retried.
- No dependencies outside Ruby's standard library. Ruby 3.0 or later.
