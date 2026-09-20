require_relative "test_helper"

class FrameEdgesTest < Minitest::Test
  WIDTH = 400
  HEIGHT = 300

  # Levels are given the way a scan reads them, in 0..255, and converted back
  # to the linear light the test images are built in.
  def linear(level)
    Emulsion::Colour.srgb_to_linear_scalar(level / 255.0)
  end

  # A scan the way a full frame scanner leaves it: bright overscan outside the
  # film, then the flat unexposed rebate, then the picture.
  def scan_with_border(rebate: [4, 26, 15], border: 24, sides: %i[left right top bottom])
    noise = Random.new(11)
    TestImages.linear_image(WIDTH, HEIGHT) do |x, y|
      depth = { left: x, right: WIDTH - 1 - x, top: y, bottom: HEIGHT - 1 - y }
      outside = sides.map { |side| depth[side] }.min
      if outside < border / 2
        [linear(250)] * 3
      elsif outside < border
        rebate.map { |level| linear(level) }
      else
        # A picture with plenty of variation, so no edge of it reads as film.
        shade = linear(30 + 200 * (((x / 29) + (y / 17)) % 2) + noise.rand(-8..8))
        [shade * 0.9, shade, shade * 1.1]
      end
    end
  end

  def test_finds_the_rebate_and_reads_its_colour
    edges = Emulsion::FrameEdges.detect(scan_with_border)
    assert edges.found?, "the rebate should be found on a full frame scan"
    floor = edges.floor
    [4, 26, 15].each_with_index do |level, channel|
      assert_in_delta level, floor[channel], 4, "channel #{channel}"
    end
    assert_equal 0.0, edges.floor_offsets[0]
    assert_in_delta 22, edges.floor_offsets[1], 4
  end

  def test_crops_to_the_picture
    left, top, width, height = Emulsion::FrameEdges.detect(scan_with_border(border: 16)).picture
    assert_operator left, :>=, 12
    assert_operator top, :>=, 12
    assert_operator left + width, :<=, WIDTH - 12
    assert_operator top + height, :<=, HEIGHT - 12
  end

  # A lab that crops to the picture leaves nothing to find, and the toolkit
  # has to carry on as before.
  def test_a_cropped_scan_has_no_border
    edges = Emulsion::FrameEdges.detect(scan_with_border(border: 0))
    refute edges.found?
    assert_nil edges.picture
    assert_nil edges.floor
    assert_nil edges.floor_offsets
  end

  # One dark even edge is a shadow in the picture until another side agrees.
  def test_one_dark_side_is_not_a_border
    edges = Emulsion::FrameEdges.detect(scan_with_border(sides: %i[left]))
    refute edges.found?
    assert_nil edges.floor
  end

  def test_a_border_deeper_than_the_cap_is_never_cropped
    deep = (WIDTH * Emulsion::FrameEdges::MAX_CROP).to_i + 12
    left, = Emulsion::FrameEdges.detect(scan_with_border(border: deep)).picture
    assert_equal 0, left, "a crop past the cap should be refused rather than eat the picture"
  end
end
