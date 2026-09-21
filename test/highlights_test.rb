require_relative "test_helper"

class HighlightsTest < Minitest::Test
  # A pixel whose gains have already been applied, so red is over the ceiling.
  def over(red: 2.0, green: 0.6, blue: 0.4)
    Vips::Image.black(16, 16).cast(:float).bandjoin([0, 0]).copy(interpretation: :srgb) +
      [red, green, blue]
  end

  def pixel(image)
    (0..2).map { |c| image[c].avg }
  end

  def test_no_headroom_leaves_the_pixel_to_clip
    frame = over
    assert_operator (Emulsion::Highlights.pull(frame, 0.0) - frame).abs.max, :<, 1e-6
  end

  def test_a_pixel_that_fits_is_left_alone
    frame = over(red: 0.9, green: 0.5, blue: 0.2)
    assert_operator (Emulsion::Highlights.pull(frame, 1.5) - frame).abs.max, :<, 1e-6
  end

  # Most of the way back rather than exactly, since the easing keeps the pull
  # gentle: a stop over the ceiling comes back almost all of it.
  def test_an_overflowing_pixel_is_brought_back_toward_white
    assert_in_delta 1.0, pixel(Emulsion::Highlights.pull(over(red: 1.2, green: 0.6, blue: 0.4), 1.5)).max, 0.03
    assert_operator pixel(Emulsion::Highlights.pull(over, 1.5)).max, :<, 1.15
  end

  # The point of it: the colour the gains asked for survives the trip.
  def test_the_colour_survives
    before = pixel(over)
    after = pixel(Emulsion::Highlights.pull(over, 1.5))
    assert_in_delta before[1] / before[0], after[1] / after[0], 0.01
    assert_in_delta before[2] / before[0], after[2] / after[0], 0.01
  end

  def test_the_darkening_is_held_to_the_limit
    out = pixel(Emulsion::Highlights.pull(over(red: 64.0, green: 20.0, blue: 12.0), 1.5))
    assert_operator out[0], :>, 64.0 * 2**-1.5, "never darker than the limit allows"
  end

  def test_a_further_overflow_is_pulled_further
    near = pixel(Emulsion::Highlights.pull(over(red: 1.2, green: 0.6, blue: 0.4), 1.5))
    far = pixel(Emulsion::Highlights.pull(over(red: 3.0, green: 1.5, blue: 1.0), 1.5))
    assert_operator near[0] / 1.2, :>, far[0] / 3.0
  end
end
