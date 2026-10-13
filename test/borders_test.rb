require_relative "test_helper"

class BordersTest < Minitest::Test
  WIDTH = 400
  HEIGHT = 300
  BORDER = 20

  def linear(level)
    FilmScan::Colour.srgb_to_linear_scalar(level / 255.0)
  end

  # Bright overscan, then a bluish rebate, then a picture that brightens
  # smoothly from left to right. A side left out has the picture run to the
  # edge, and its crop is borrowed from the side opposite.
  def scan_with_border(sides: %i[left right top bottom])
    noise = Random.new(5)
    TestImages.linear_image(WIDTH, HEIGHT) do |x, y|
      depth = { left: x, right: WIDTH - 1 - x, top: y, bottom: HEIGHT - 1 - y }
      outside = sides.map { |side| depth[side] }.min
      if outside < BORDER / 2
        [linear(250)] * 3
      elsif outside < BORDER
        [linear(4), linear(18), linear(30)]
      else
        shade = linear(30 + 160.0 * x / WIDTH + 30.0 * y / HEIGHT + noise.rand(-6..6))
        [shade * 1.1, shade, shade * 0.8]
      end
    end
  end

  def options(crop)
    FilmScan::DEFAULTS.merge(FilmScan::Profile.load("lucky-shd-400").settings)
                      .merge(fix: FilmScan::DEFAULT_FIXES, crop: crop)
  end

  def test_borders_stay_unless_crop_asks
    scan = scan_with_border
    kept = FilmScan::Pipeline.new(options(false)).render(scan)
    cropped = FilmScan::Pipeline.new(options(true)).render(scan)
    _, _, width, height = FilmScan::FrameEdges.detect(scan).picture

    assert_equal [WIDTH, HEIGHT], [kept.width, kept.height]
    assert_equal [width, height], [cropped.width, cropped.height]
    assert_operator width, :<, WIDTH
  end

  # The borders are carried along and never measured, so the picture comes
  # out the same whether they were kept or not, give or take the filters
  # that are sized to the whole frame. Measuring them is ten times this.
  def test_a_kept_border_does_not_change_the_picture
    scan = scan_with_border
    kept = FilmScan::Pipeline.new(options(false)).render(scan)
    cropped = FilmScan::Pipeline.new(options(true)).render(scan)
    left, top, width, height = FilmScan::FrameEdges.detect(scan).picture

    inset = 8
    picture = kept.extract_area(left + inset, top + inset, width - 2 * inset, height - 2 * inset)
    alone = cropped.extract_area(inset, inset, width - 2 * inset, height - 2 * inset)
    difference = (picture - alone).abs
    assert_operator difference.avg, :<, 0.005
    assert_operator difference.max, :<, 0.04
  end

  # A strip of picture can sit outside the area measured, here because the
  # left side has no border and borrows its crop from the right. It is
  # corrected along with the rest, so no step marks where the measuring stopped.
  def test_no_seam_where_the_measured_area_ends
    scan = scan_with_border(sides: %i[right top bottom])
    left, = FilmScan::FrameEdges.detect(scan).picture
    assert_operator left, :>, 10

    kept = FilmScan::Pipeline.new(options(false)).render(scan)
    column = ->(x) { kept.extract_area(x, 60, 3, 180).avg }
    across = column[left + 1] - column[left - 4]
    beyond = column[left + 6] - column[left + 1]
    assert_operator across, :<, beyond * 1.25
  end

  def test_crop_is_its_own_flag
    error = assert_raises(ArgumentError) { FilmScan::CLI.fixes_from(["crop"]) }
    assert_match(/--crop/, error.message)
    refute_includes FilmScan::DEFAULT_FIXES, :crop
  end

  def test_a_conversion_keeps_its_borders_unless_crop_asks
    Dir.mktmpdir do |dir|
      source = File.join(dir, "roll")
      Dir.mkdir(source)
      (scan_with_border * 255).cast(:uchar).pngsave(File.join(source, "000001.png"))
      picture = FilmScan::FrameEdges.detect(scan_with_border).picture

      [[[], [WIDTH, HEIGHT]], [["--crop"], picture.last(2)]].each do |flags, size|
        out_dir = File.join(dir, "out#{flags.size}")
        status = nil
        out, = capture_io do
          status = FilmScan::CLI.run(["--convert-only", *flags, "--format", "png", "--out", out_dir, source])
        end
        assert_equal 0, status, out
        written = Vips::Image.new_from_file(File.join(out_dir, "000001.png"))
        assert_equal size, [written.width, written.height], flags.inspect
      end
    end
  end
end
