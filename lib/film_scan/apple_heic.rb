module FilmScan
  # Apple's hardware HEVC encoder, through a small Swift helper that
  # `rake apple_heic` builds. It writes the same 10-bit 4:4:4 HEIC as
  # heif-enc, about eight times faster and on the media engine rather than
  # the cores, at slightly lower fidelity for the size.
  module AppleHeic
    HELPER = File.expand_path("../../libexec/apple-heic", __dir__)

    # The helper's exit status for a frame denser or noisier than the encoder
    # has coded cleanly. A frame of noise hung the encoder and the kernel
    # panicked.
    REFUSED = 3

    module_function

    def available? = unavailable_reason.nil?

    # Why --encoder apple can't be used here, or nil when it can.
    def unavailable_reason
      return "--encoder apple needs macOS; leave it at x265 here" unless RUBY_PLATFORM.include?("darwin")
      return "--encoder apple needs its helper built first: run `bundle exec rake apple_heic`" unless File.executable?(HELPER)

      nil
    end

    # What heif-enc writes instead, and why, or nil when the helper can write
    # the frame.
    def handed_back(bands, bits, quality)
      # The hardware writes true monochrome, but Apple's own decoder reads it
      # as colour with red and blue a level below green.
      return "black and white, as Apple's decoder reads the hardware's monochrome off grey" if bands == 1
      return "lossless HEIC, which Apple's encoder has no mode for" if quality >= 100
      return "#{bits}-bit HEIC, as Apple's encoder stops at 10 bits" if bits > 10
      return "8-bit HEIC, which has not been measured on the hardware encoder" if bits < 10

      nil
    end

    def command(png, heic, qp:, bits:, threads:)
      [HELPER, "--qp", qp.to_s, "--bits", bits.to_s, "--threads", threads.to_s, png, heic]
    end
  end
end
