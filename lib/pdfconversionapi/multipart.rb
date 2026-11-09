# frozen_string_literal: true

require "securerandom"
require "stringio"

module PdfConversionApi
  # A multipart/form-data body, written by hand.
  #
  # Net::HTTP's own form encoder (Net::HTTP::Post#set_form) escapes a double quote as \" and
  # leaves CR and LF alone. The API reads only a plain filename="..." in raw UTF-8 (never
  # filename*), and it reads escapes such as %22 literally:
  #
  # - in a file name, a quote, CR or LF is sent as _ (the API turns a quote into _ itself when
  #   it cleans the name);
  # - in a field (parameter) name, they are sent as %22, %0D and %0A, so an invalid name stays
  #   invalid and the API refuses it, instead of quietly ignoring a renamed one.
  #
  # Files given by path are streamed from disk and opened again for each attempt.
  #
  # @api private
  class Multipart
    CRLF = "\r\n"
    FIELD_NAME_ESCAPES = { '"' => "%22", "\r" => "%0D", "\n" => "%0A" }.freeze
    RAW_ENCODINGS = [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].freeze

    class << self
      # A field name for name="...": raw UTF-8, with ", CR and LF as %22, %0D and %0A.
      def escape_field_name(value)
        utf8_bytes(value).gsub(/["\r\n]/n) { |c| FIELD_NAME_ESCAPES.fetch(c) }
      end

      # A file name for filename="...": raw UTF-8, with ", CR and LF replaced by _.
      def escape_file_name(value)
        utf8_bytes(value).gsub(/["\r\n]/n, "_")
      end

      # The string's bytes as UTF-8, without a conversion when it already is (or is binary).
      def utf8_bytes(value)
        value = value.to_s
        value = value.encode(Encoding::UTF_8) unless RAW_ENCODINGS.include?(value.encoding)
        value.b
      end
    end

    # @return [String]
    attr_reader :boundary

    def initialize(boundary: "pdfconversionapi-#{SecureRandom.hex(16)}")
      @boundary = boundary
      @segments = [] # binary Strings and UploadFiles, in body order
    end

    # @return [String] the Content-Type header value
    def content_type
      "multipart/form-data; boundary=#{@boundary}"
    end

    # Adds a text field.
    def add_text(name, value)
      push("--#{@boundary}#{CRLF}".b)
      push("Content-Disposition: form-data; name=\"#{self.class.escape_field_name(name)}\"#{CRLF}#{CRLF}".b)
      push(self.class.utf8_bytes(value))
      push(CRLF.b)
      self
    end

    # Adds a file field.
    def add_file(name, upload)
      push("--#{@boundary}#{CRLF}".b)
      push(
        "Content-Disposition: form-data; name=\"#{self.class.escape_field_name(name)}\"; " \
        "filename=\"#{self.class.escape_file_name(upload.name)}\"#{CRLF}" \
        "Content-Type: application/octet-stream#{CRLF}#{CRLF}".b
      )
      @segments << upload
      push(CRLF.b)
      self
    end

    # A new stream over the whole body, and its length. Call once per attempt: files given by
    # path are opened again and their size is read again.
    #
    # @return [Array(BodyStream, Integer)]
    def stream
      segments = @segments + ["--#{@boundary}--#{CRLF}".b]
      length = segments.sum { |s| s.is_a?(String) ? s.bytesize : s.size }
      [BodyStream.new(segments), length]
    end

    # The whole body as one String (for tests and small bodies).
    def to_s
      body, = stream
      body.read
    ensure
      body&.close
    end

    private

    def push(bytes)
      if @segments.last.is_a?(String)
        @segments[-1] = @segments.last + bytes
      else
        @segments << bytes
      end
    end

    # Reads the segments one after the other. Files are opened when reached and closed when
    # done. Implements the #read that IO.copy_stream (used by Net::HTTP's body_stream) needs.
    class BodyStream
      def initialize(segments)
        @segments = segments
        @index = 0
        @io = nil
      end

      # Reads up to +length+ bytes (everything left when nil). Returns nil at the end when a
      # length is given, like IO#read.
      def read(length = nil, outbuf = nil)
        out = outbuf ? outbuf.replace("".b) : +"".b
        while length.nil? || out.bytesize < length
          io = current_io
          break unless io

          chunk = io.read(length ? length - out.bytesize : nil)
          if chunk.nil? || chunk.empty?
            advance
          else
            out << chunk
          end
        end
        return nil if length&.positive? && out.empty?

        out
      end

      def close
        @io&.close
        @io = nil
        @index = @segments.length
        nil
      end

      private

      def current_io
        return @io if @io
        return nil if @index >= @segments.length

        segment = @segments[@index]
        @io = segment.is_a?(String) ? StringIO.new(segment) : segment.open_io
      end

      def advance
        @io&.close
        @io = nil
        @index += 1
      end
    end
  end
end
