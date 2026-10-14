require_relative "test_helper"

class OutputFormatTest < Minitest::Test
  def setup
    @cli = FilmScan::CLI.new
    @frame = TestImages.linear_image(64, 48) do |x, y|
      shade = 0.02 + 0.9 * (x / 63.0)
      [shade, shade * 0.95, shade * 0.9 + y / 480.0]
    end
  end

  def save(format, bits: 16, quality: 98, frame: @frame, orientation: 1, **options)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "frame#{FilmScan::CLI::FORMATS.fetch(format)}")
      @cli.send(:save, frame, path, format, FilmScan::DEFAULTS.merge(bits: bits, quality: quality, **options), orientation)
      yield Vips::Image.new_from_file(path), File.size(path)
    end
  end

  def test_every_format_writes_a_readable_frame
    %w[tiff png jpeg heic jp2].each do |format|
      save(format) do |image, size|
        assert_equal 64, image.width, format
        assert_equal 48, image.height, format
        assert_operator image.bands, :>=, 3, format
        assert_operator size, :>, 0, format
      end
    end
  end

  def test_depth_follows_what_the_format_can_hold
    assert_equal 16, @cli.send(:depth_for, "tiff", 16)
    assert_equal 8, @cli.send(:depth_for, "tiff", 8)
    assert_equal 8, @cli.send(:depth_for, "jpeg", 16), "jpeg only has eight"
    assert_equal 12, @cli.send(:depth_for, "heic", 16), "heic stops at twelve"
    assert_equal 8, @cli.send(:depth_for, "heic", 8)
  end

  # Asked for nothing, each format takes the depth it carries well. HEIC gets
  # ten bits from libheif's encoder, and eight from libvips', whose deeper
  # modes measure worse.
  def test_each_format_has_a_depth_it_takes_by_default
    assert_equal 16, @cli.send(:depth_for, "tiff", nil)
    assert_equal 16, @cli.send(:depth_for, "jp2", nil)
    assert_equal FilmScan::CLI::HEIF_ENC ? 10 : 8, @cli.send(:depth_for, "heic", nil)
    assert_equal 8, @cli.send(:depth_for, "jpeg", nil)
  end

  def test_sixteen_bit_formats_keep_their_depth
    save("tiff", bits: 16) { |image, _| assert_equal :ushort, image.format }
    save("tiff", bits: 8) { |image, _| assert_equal :uchar, image.format }
    save("png", bits: 16) { |image, _| assert_equal :ushort, image.format }
  end

  def test_eight_bits_costs_less_than_sixteen
    big = save("tiff", bits: 16) { |_, size| size }
    small = save("tiff", bits: 8) { |_, size| size }
    assert_operator small, :<, big
  end

  # Without dither a stretched gradient steps; with it the steps become noise,
  # so neighbouring columns stop landing on exactly one value.
  def test_eight_bit_output_is_dithered
    ramp = TestImages.linear_image(256, 64) { |x, _| [0.2 + 0.05 * (x / 255.0)] * 3 }
    eight = @cli.send(:quantise, ramp, 8)
    column = (0...64).map { |y| eight.getpoint(100, y).first }
    assert_operator column.uniq.size, :>, 1, "a flat column should carry dither"
    assert_in_delta ramp.getpoint(100, 0).first * 255, column.sum / column.size.to_f, 1.0
  end

  def test_sixteen_bit_output_is_not_dithered
    flat = TestImages.linear_image(32, 32) { |_x, _y| [0.5, 0.5, 0.5] }
    deep = @cli.send(:quantise, flat, 16)
    assert_equal 1, (0...32).map { |y| deep.getpoint(5, y).first }.uniq.size
  end

  # The HEVC encoder gives the same file at 95 and at 100, so lossless is the
  # only way to ask it for more.
  def test_quality_one_hundred_asks_for_lossless
    lossy = save("heic", quality: 95) { |_, size| size }
    lossless = save("heic", quality: 100) { |_, size| size }
    assert_operator lossless, :>, lossy
  end

  def test_black_and_white_is_written_as_one_channel
    save("png", monochrome: true) { |image, _| assert_equal 1, image.bands }
  end

  # Left tagged as sRGB, one channel came out of PNG at eight bits and out of
  # JPEG 2000 as three channels.
  def test_black_and_white_keeps_sixteen_bits_in_one_channel
    %w[png tiff jp2].each do |format|
      save(format, bits: 16, monochrome: true) do |image, _|
        assert_equal :ushort, image.format, format
        assert_equal 1, image.bands, format
      end
    end
  end

  def heif_info(format_options = {})
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    Dir.mktmpdir do |dir|
      path = File.join(dir, "frame.heic")
      @cli.send(:save, format_options.delete(:frame) || @frame, path, "heic",
                FilmScan::DEFAULTS.merge(bits: nil, quality: 98, **format_options), format_options.delete(:orientation) || 1)
      yield `heif-info "#{path}" 2>&1`, Vips::Image.new_from_file(path)
    end
  end

  # Full colour resolution in colour, and true monochrome in black and white.
  def test_heic_keeps_colour_at_full_resolution
    heif_info do |info, _|
      assert_match(/4:4:4/, info)
      assert_match(/bit depth: 10/, info)
    end
  end

  def test_black_and_white_heic_is_monochrome
    heif_info(monochrome: true) do |info, _|
      assert_match(/monochrome/, info)
      assert_match(/bit depth: 10/, info)
    end
  end

  # libde265, the decoder behind libheif and most software outside Apple's,
  # cannot open a picture over about 16 MB in one piece, and a corrected frame
  # is often more, so HEIC is always written in slices.
  def test_heic_is_written_in_slices
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    calls = []
    @cli.define_singleton_method(:system) do |*args, **opts|
      calls << args
      super(*args, **opts)
    end
    heif_info { |info, _| assert_match(/4:4:4/, info) }
    assert(calls.any? { |args| args.include?("x265:slices=4") }, calls.inspect)
  end

  # heif-enc runs on a thread of its own, and a failure there still reaches
  # the run and takes the temporary files with it.
  def test_a_failed_heic_encode_is_reported_and_cleaned_up
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    def @cli.system(*) = false
    Dir.mktmpdir do |dir|
      path = File.join(dir, "frame.heic.partial")
      error = assert_raises(RuntimeError) do
        @cli.send(:save, @frame, path, "heic", FilmScan::DEFAULTS.merge(bits: 10), 1)
      end
      assert_match(/heif-enc could not write/, error.message)
      assert_empty Dir.children(dir)
    end
  end

  # The PNG the encoder reads carries no orientation, so a portrait frame is
  # turned upright before it is written.
  def test_a_portrait_frame_is_written_upright
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    save("heic", bits: 10, orientation: 6) do |image, _|
      assert_equal 48, image.width
      assert_equal 64, image.height
    end
  end

  def test_format_names_people_actually_type
    assert_equal "jpeg", @cli.send(:output_format, "x.tiff", { format: "jpg" })
    assert_equal "heic", @cli.send(:output_format, "x.tiff", { format: "heif" })
    assert_equal "jp2", @cli.send(:output_format, "x.tiff", { format: "jpeg2000" })
    assert_equal "tiff", @cli.send(:output_format, "x.tiff", {})
    assert_equal "heic", @cli.send(:output_format, "x.HEIC", {})
  end
end
