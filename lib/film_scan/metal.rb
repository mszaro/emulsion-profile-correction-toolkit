require "ffi"

module FilmScan
  # The GPU behind --engine apple, through the library `rake apple_engine`
  # builds. It compiles the kernels Fused writes, keeps each by its source, and
  # runs them over float images in memory.
  module Metal
    LIBRARY = File.expand_path("../../libexec/libfilmscan-engine.dylib", __dir__)
    REASON = 2048

    # Why --engine apple cannot run here, or nil when it can.
    def self.unavailable_reason
      return "--engine apple needs macOS" unless RUBY_PLATFORM.include?("darwin")
      return "--engine apple needs `rake apple_engine` first" unless File.exist?(LIBRARY)

      load!
      nil
    rescue LoadError, RuntimeError => e
      e.message
    end

    def self.available? = unavailable_reason.nil?

    # The engine a run uses when it asks for none.
    def self.default_engine = available? ? "apple" : "vips"

    module Native
      extend FFI::Library
    end

    # The pixel data of a vips image held in memory, from libvips itself.
    module Libvips
      extend FFI::Library
      ffi_lib FFI.library_name("vips", 42)
      attach_function :vips_image_get_data, [:pointer], :pointer
    end

    class << self
      def load!
        return if @engine

        Native.ffi_lib LIBRARY
        Native.attach_function :fs_engine_open, [], :pointer
        Native.attach_function :fs_engine_alloc, [:size_t], :pointer
        Native.attach_function :fs_engine_free, [:pointer], :void
        Native.attach_function :fs_engine_compile, %i[pointer string pointer size_t], :pointer
        Native.attach_function :fs_engine_run,
                               %i[pointer pointer pointer pointer pointer int pointer size_t pointer size_t uint32
                                  pointer size_t], :int
        engine = Native.fs_engine_open
        raise "--engine apple found no Metal device" if engine.null?

        @engine = engine
        @kernels = {}
      end

      # Ruby's collector sees none of this memory, so it is asked to look every
      # few frames' worth, or finished frames pile up unfreed.
      COLLECT_EVERY = 4 << 30

      # Memory the GPU writes in place, freed once nothing holds it.
      def alloc(bytes)
        load!
        @since_collect = (@since_collect || 0) + bytes
        if @since_collect > COLLECT_EVERY
          GC.start
          @since_collect = 0
        end
        raw = Native.fs_engine_alloc(bytes)
        raise NoMemoryError, "no room for a #{bytes} byte frame" if raw.null?

        FFI::AutoPointer.new(raw.slice(0, bytes), Native.method(:fs_engine_free))
      end

      def kernel(source)
        load!
        @kernels[source] ||= begin
          reason = FFI::MemoryPointer.new(:char, REASON)
          compiled = Native.fs_engine_compile(@engine, source, reason, REASON)
          raise "Metal would not compile a kernel: #{reason.read_string}" if compiled.null?

          compiled
        end
      end

      def kernels = @kernels&.size || 0

      # Runs `source` over `inputs`, each [pointer, bytes, owned], writing
      # `pixels` pixels into `output`, an alloc'd pointer.
      def run(source, inputs, constants, output, pixels)
        compiled = kernel(source)
        pointers = FFI::MemoryPointer.new(:pointer, [inputs.size, 1].max)
        lengths = FFI::MemoryPointer.new(:size_t, [inputs.size, 1].max)
        owned = FFI::MemoryPointer.new(:uint8, [inputs.size, 1].max)
        inputs.each_with_index do |(pointer, bytes, mine), i|
          pointers.put_pointer(i * FFI::Pointer.size, pointer)
          lengths.put(:size_t, i * FFI.type_size(:size_t), bytes)
          owned.put_uint8(i, mine ? 1 : 0)
        end
        table = constants.empty? ? nil : FFI::MemoryPointer.new(:float, constants.size).put_array_of_float(0, constants)
        reason = FFI::MemoryPointer.new(:char, REASON)
        status = Native.fs_engine_run(@engine, compiled, pointers, lengths, owned, inputs.size, table,
                                      constants.size * 4, output, output.size, pixels, reason, REASON)
        raise "a Metal kernel failed (#{status}): #{reason.read_string}" unless status.zero?

        output
      end
    end
  end
end
