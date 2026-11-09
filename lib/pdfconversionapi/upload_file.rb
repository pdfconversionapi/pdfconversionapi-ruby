# frozen_string_literal: true

require "pathname"

module PdfConversionApi
  # One file to upload: its bytes (or the path to read them from) and the name sent with them.
  #
  # You rarely need this class: methods that take files also accept a path (String or Pathname)
  # or an open IO. Use it to upload bytes from memory, or to send a different name:
  #
  #   PdfConversionApi::UploadFile.from_bytes(pdf_bytes, "invoice.pdf")
  #   PdfConversionApi::UploadFile.from_io(request.body, "upload.docx")
  #   PdfConversionApi::UploadFile.from_path("tmp/1234", "report.docx")
  class UploadFile
    # The name used when none is given.
    DEFAULT_NAME = "file"
    # Encodings whose bytes are taken as UTF-8 as they are.
    RAW_ENCODINGS = [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].freeze
    private_constant :RAW_ENCODINGS

    # @return [String] the name sent with the file (its own name, without folders)
    attr_reader :name
    # @return [String, nil] the path the bytes are read from, nil for bytes in memory
    attr_reader :path

    class << self
      # A file on disk. It is opened again for each attempt, so retries send the same bytes.
      # The name sent is the path's last part, unless +name+ is given.
      #
      # @param path [String, Pathname]
      # @param name [String, nil]
      def from_path(path, name = nil)
        path = path_string(path)
        raise ArgumentError, "path must not be empty" if path.empty?
        raise Errno::ENOENT, path unless File.exist?(path)
        raise Errno::EISDIR, path if File.directory?(path)

        new(path: path, name: name || File.basename(path))
      end

      # Bytes in memory. Without a name the file is sent as "file".
      #
      # @param data [String] the bytes (any encoding; sent as they are)
      # @param name [String, nil]
      def from_bytes(data, name = nil)
        raise ArgumentError, "data must be a String of bytes, got #{data.class}" unless data.is_a?(String)

        new(data: data.b, name: name)
      end

      # An IO or any object with #read (File, StringIO, Tempfile, a Rack upload...). It is read
      # into memory once, before the first attempt, so retries send the same bytes. Without a
      # name, a File is sent under its own name and anything else as "file".
      #
      # @param io [#read]
      # @param name [String, nil]
      def from_io(io, name = nil)
        raise ArgumentError, "#{io.class} doesn't respond to #read" unless io.respond_to?(:read)

        name ||= File.basename(io.to_path.to_s) if io.respond_to?(:to_path)
        data = io.read
        raise ArgumentError, "#{io.class}#read returned #{data.class}, not a String" unless data.is_a?(String)

        new(data: data.b, name: name)
      end
      alias from_stream from_io

      # Turns what a caller passed into an UploadFile: a String or Pathname is a path, an object
      # with #read is a stream, an UploadFile is used as it is.
      #
      # @api private
      def coerce(input)
        case input
        when UploadFile then input
        when String, Pathname then from_path(input)
        else
          return from_io(input) if input.respond_to?(:read)
          return from_path(input) if input.respond_to?(:to_path)

          raise ArgumentError,
                "a file must be a path (String or Pathname), an IO, or a PdfConversionApi::UploadFile; " \
                "got #{input.class}"
        end
      end

      # Whether +value+ is something #coerce reads as a file when it is a parameter's value.
      # A String is text there, never a path.
      #
      # @api private
      def file_like?(value)
        value.is_a?(UploadFile) || value.is_a?(Pathname) || value.respond_to?(:read)
      end

      # The file's own name: everything up to the last / or \ removed. Empty means "file".
      #
      # @api private
      def base_name(name)
        name = name.to_s
        name = name.encode(Encoding::UTF_8) unless RAW_ENCODINGS.include?(name.encoding)
        bytes = name.b
        cut = [bytes.rindex("/"), bytes.rindex("\\")].compact.max
        bytes = bytes[(cut + 1)..] if cut
        bytes.empty? ? DEFAULT_NAME : bytes.force_encoding(Encoding::UTF_8)
      end

      # A path given as a String, a Pathname or anything with #to_path, as a String.
      #
      # @api private
      def path_string(path)
        case path
        when String then path
        when Pathname then path.to_s
        else
          raise ArgumentError, "path must be a String or Pathname, got #{path.class}" unless path.respond_to?(:to_path)

          path.to_path.to_s
        end
      end
    end

    # Use UploadFile.from_path, .from_bytes or .from_io.
    def initialize(name:, path: nil, data: nil)
      @path = path
      @data = data
      @name = self.class.base_name(name).freeze
      freeze
    end

    # The size in bytes, read again from disk for a path.
    #
    # @return [Integer]
    def size
      @path ? File.size(@path) : @data.bytesize
    end

    # An IO over the bytes, opened anew each time. The caller closes it.
    #
    # @api private
    def open_io
      @path ? File.open(@path, "rb") : StringIO.new(@data)
    end

    def inspect
      source = @path ? "path=#{@path.inspect}" : "bytes=#{@data.bytesize}"
      "#<#{self.class.name} name=#{@name.inspect} #{source}>"
    end
  end
end
