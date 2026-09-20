require_relative "test_helper"

class OutputFormatTest < Minitest::Test
  def setup
    @cli = Emulsion::CLI.new
    @frame = TestImages.linear_image(64, 48) do |x, y|
      shade = 0.02 + 0.9 * (x / 63.0)
      [shade, shade * 0.95, shade * 0.9 + y / 480.0]
    end
  end

  def save(format, bits: 16, quality: 98)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "frame#{Emulsion::CLI::FORMATS.fetch(format)}")
      @cli.send(:save, @frame, path, format, Emulsion::DEFAULTS.merge(bits: bits, quality: quality))
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

  # Asked for nothing, each format takes the depth it carries well. HEIC's
  # deeper modes measure worse than its eight, so eight is what it gets.
  def test_each_format_has_a_depth_it_takes_by_default
    assert_equal 16, @cli.send(:depth_for, "tiff", nil)
    assert_equal 16, @cli.send(:depth_for, "jp2", nil)
    assert_equal 8, @cli.send(:depth_for, "heic", nil)
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

  def test_format_names_people_actually_type
    assert_equal "jpeg", @cli.send(:output_format, "x.tiff", { format: "jpg" })
    assert_equal "heic", @cli.send(:output_format, "x.tiff", { format: "heif" })
    assert_equal "jp2", @cli.send(:output_format, "x.tiff", { format: "jpeg2000" })
    assert_equal "tiff", @cli.send(:output_format, "x.tiff", {})
    assert_equal "heic", @cli.send(:output_format, "x.HEIC", {})
  end
end
