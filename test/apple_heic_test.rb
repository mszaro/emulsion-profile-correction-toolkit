require_relative "test_helper"
require "json"

# --encoder apple where it can't run, and what the CLI does when the helper
# refuses a frame or fails. A stand-in script plays the helper, so nothing
# here reaches the hardware encoder.
class AppleHeicRoutingTest < Minitest::Test
  def setup
    @cli = FilmScan::CLI.new
    @frame = TestImages.linear_image(64, 48) do |x, y|
      shade = 0.02 + 0.9 * (x / 63.0)
      [shade, shade * 0.95, shade * 0.9 + y / 480.0]
    end
  end

  # Swaps a method for the length of the block. minitest 6 no longer ships
  # minitest/mock, and plain `rake test` runs it.
  def replacing(target, name, impl)
    original = target.method(name)
    quietly { target.singleton_class.send(:define_method, name, impl) }
    yield
  ensure
    quietly { target.singleton_class.send(:define_method, name, original) }
  end

  # Redefining a method on purpose, without Ruby warning that it was.
  def quietly
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end

  def with_helper(script)
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "apple-heic")
      File.write(fake, "#!/bin/sh\n#{script}\n")
      File.chmod(0o755, fake)
      replacing(FilmScan::AppleHeic, :command, ->(png, heic, **) { [fake, png, heic] }) { yield }
    end
  end

  def save(dir, **options)
    path = File.join(dir, "frame.heic.partial")
    out, = capture_io do
      @cli.send(:save, options.delete(:frame) || @frame, path, "heic",
                FilmScan::DEFAULTS.merge(encoder: "apple", bits: 10, **options), 1)
    end
    [path, out]
  end

  def test_asking_for_it_where_it_cannot_run_says_what_it_needs
    Dir.mktmpdir do |dir|
      (Vips::Image.black(16, 16, bands: 3) + 128).cast(:uchar).pngsave(File.join(dir, "000001.png"))
      status = nil
      _, err = capture_io do
        replacing(File, :executable?, ->(*) { false }) do
          status = FilmScan::CLI.run(["--convert-only", "--format", "heic", "--encoder", "apple", dir])
        end
      end
      assert_equal 1, status
      assert_match(RUBY_PLATFORM.include?("darwin") ? /rake apple_heic/ : /needs macOS/, err)
      refute Dir.exist?("#{dir} - corrected"), "nothing should be written"
    end
  end

  # The helper refuses a frame denser than the encoder has coded cleanly,
  # and heif-enc writes that frame from the same PNG.
  def test_a_refused_frame_is_written_by_heif_enc
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    with_helper("echo 'apple-heic: too dense for the hardware encoder' >&2; exit #{FilmScan::AppleHeic::REFUSED}") do
      Dir.mktmpdir do |dir|
        path, out = save(dir)
        assert_match(/frame\.heic: heif-enc writes it, too dense for the hardware encoder/, out)
        assert_match(/4:4:4/, `heif-info "#{path}" 2>&1`)
        assert_equal ["frame.heic.partial"], Dir.children(dir)
      end
    end
  end

  def test_a_failed_encode_is_reported_and_cleaned_up
    with_helper("echo 'apple-heic: cannot read it' >&2; exit 1") do
      Dir.mktmpdir do |dir|
        error = assert_raises(RuntimeError) { save(dir) }
        assert_match(/Apple's encoder could not write .*: cannot read it/, error.message)
        assert_empty Dir.children(dir)
      end
    end
  end

  # Apple's decoder reads the hardware's monochrome off grey, so heif-enc
  # writes black and white without the helper being asked.
  def test_black_and_white_goes_to_heif_enc
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    with_helper("exit 1") do
      Dir.mktmpdir do |dir|
        path, out = save(dir, monochrome: true)
        assert_match(/heif-enc writes black and white/, out)
        assert_match(/monochrome/, `heif-info "#{path}" 2>&1`)
      end
    end
  end

  def test_lossless_goes_to_heif_enc
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    with_helper("exit 1") do
      Dir.mktmpdir { |dir| assert_match(/heif-enc writes lossless/, save(dir, quality: 100).last) }
    end
  end
end

# The hardware encoder itself, on the owner's real frames only: a folder of
# 16-bit PNG renders or scans named by APPLE_HEIC_FRAMES. A frame of noise
# once hung the encoder and panicked the kernel, so nothing synthetic is ever
# given to it, and these run only when asked for.
class AppleHeicEncoderTest < Minitest::Test
  FRAMES = ENV["APPLE_HEIC_FRAMES"].to_s

  def setup
    skip "set APPLE_HEIC_FRAMES to a folder of real 16-bit PNG frames" if FRAMES.empty?
    skip FilmScan::AppleHeic.unavailable_reason unless FilmScan::AppleHeic.available?
    skip "heif-dec is not installed" unless system("which heif-dec", out: File::NULL)
    @frames = Dir[File.join(FRAMES, "*.png")].sort
    skip "no PNG frames in #{FRAMES}" if @frames.empty?
  end

  def helper(*args) = Open3.capture2e(FilmScan::AppleHeic::HELPER, *args)

  # PSNR in 10-bit levels, with white at 1023. heif-dec writes a ten bit
  # level v as v << 6, and sips as v * 65535 / 1023.
  def psnr(source, decoded, shifted:)
    a = Vips::Image.new_from_file(source).cast(:double) * 1023 / 65535
    b = Vips::Image.new_from_file(decoded).cast(:double)
    b = b.extract_band(0, n: a.bands) if b.bands > a.bands
    b = shifted ? b / 64 : (b * 1023 / 65535).rint
    10 * Math.log10(1023.0**2 / ((a - b)**2).avg)
  end

  # The sizes of a HEIF file's items, from its iloc box (version 1, as the
  # helper writes it).
  def item_sizes(path)
    data = File.binread(path)
    at = data.index("iloc") or flunk "no iloc in #{path}"
    count = data[at + 10, 2].unpack1("n")
    (0...count).map { |i| data[at + 12 + i * 16 + 12, 4].unpack1("N") }
  end

  def encode(png, heic)
    said, status = helper("--qp", "1", png, heic)
    skip "the guard handed #{File.basename(png)} to x265: #{said.strip}" if status.exitstatus == FilmScan::AppleHeic::REFUSED
    assert status.success?, said
  end

  def test_a_real_frame_decodes_in_libheif_libvips_and_imageio
    Dir.mktmpdir do |dir|
      png = @frames.first
      heic = File.join(dir, "frame.heic")
      encode(png, heic)
      info = `heif-info "#{heic}" 2>&1`
      assert_match(/4:4:4/, info)
      assert_match(/bit depth: 10/, info)
      assert_match(/tiles:/, info)

      assert system("heif-dec", heic, File.join(dir, "libheif.png"), out: File::NULL, err: File::NULL)
      assert_operator psnr(png, File.join(dir, "libheif.png"), shifted: true), :>, 50
      assert system("sips", "-s", "format", "png", heic, "--out", File.join(dir, "imageio.png"), out: File::NULL)
      assert_operator psnr(png, File.join(dir, "imageio.png"), shifted: false), :>, 50
      assert_equal Vips::Image.new_from_file(png).width, Vips::Image.new_from_file(heic).width
    end
  end

  # Over 16 MB in all, but no one picture near it, so libde265 opens it.
  def test_a_frame_too_big_for_one_picture_decodes_as_tiles
    Dir.mktmpdir do |dir|
      heic = File.join(dir, "frame.heic")
      png = @frames.find { |frame| File.size(frame) > 100_000_000 } || skip("no full size frame in #{FRAMES}")
      encode(png, heic)
      sizes = item_sizes(heic)
      skip "#{File.basename(png)} coded under 16 MB" if sizes.sum < 16 * 1024 * 1024
      assert_operator sizes.max, :<, 12 * 1024 * 1024
      assert system("heif-dec", heic, File.join(dir, "out.png"), out: File::NULL, err: File::NULL)
    end
  end

  # The helper is given the frame already turned upright, as heif-enc is.
  def test_a_portrait_frame_is_written_upright
    crop = Vips::Image.new_from_file(@frames.first).crop(1000, 1000, 640, 480).cast(:float) / 65535
    crop = crop.copy(interpretation: :srgb)
    cli = FilmScan::CLI.new
    Dir.mktmpdir do |dir|
      written = %w[apple x265].to_h do |encoder|
        path = File.join(dir, "#{encoder}.heic")
        capture_io { cli.send(:save, crop, path, "heic", FilmScan::DEFAULTS.merge(encoder: encoder, bits: 10), 6) }
        [encoder, Vips::Image.new_from_file(path)]
      end
      assert_equal [480, 640], [written["apple"].width, written["apple"].height]
      assert_operator (written["apple"].cast(:double) - written["x265"]).abs.avg, :<, 0.01 * 65535
    end
  end

  def test_the_guard_refuses_before_encoding
    Dir.mktmpdir do |dir|
      heic = File.join(dir, "frame.heic")
      said, status = helper("--qp", "1", "--max-density", "0.01", @frames.first, heic)
      assert_equal FilmScan::AppleHeic::REFUSED, status.exitstatus, said
      assert_match(/too dense for the hardware encoder/, said)
      refute File.exist?(heic)

      said, status = helper("--qp", "1", "--check", @frames.first)
      assert status.success?, said
      assert_includes JSON.parse(said).keys, "densest"
      _, status = helper("--qp", "1", "--max-density", "99", @frames.first, heic)
      refute status.success?, "the guard cannot be loosened"
    end
  end
end
