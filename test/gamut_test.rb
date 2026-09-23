require_relative "test_helper"

class GamutTest < Minitest::Test
  def pixel(*values)
    Vips::Image.black(16, 16).cast(:float).bandjoin([0.0, 0.0]) + values
  end

  def read(image)
    (0..2).map { |c| image[c].avg }
  end

  # Hue as the angle of the colour against grey, which is what clipping
  # destroys and this is meant to keep.
  def hue(values)
    Math.atan2(values[2] - (values[0] + values[1]) / 2.0, values[0] - values[1])
  end

  def test_a_pixel_that_fits_is_left_alone
    frame = pixel(0.6, 0.4, 0.2)
    assert_operator (Emulsion::Gamut.fit(frame) - frame).abs.max, :<, 1e-5
  end

  def test_an_over_range_pixel_comes_back_inside
    out = read(Emulsion::Gamut.fit(pixel(1.4, 1.1, 0.7)))
    assert_operator out.max, :<=, 1.0 + 1e-6
    assert_operator out.min, :>, 0.5, "and is not simply darkened away"
  end

  # The point of it: clipping takes the channels down one by one and turns the
  # colour, and this keeps the hue it was.
  def test_it_keeps_the_hue_that_clipping_would_turn
    over = pixel(1.35, 1.05, 0.55)
    linear = Emulsion::Colour.to_linear(over)
    fitted = Emulsion::Colour.to_linear(Emulsion::Gamut.fit(over))
    clipped = Emulsion::Colour.clamp01(linear)
    wanted = hue(read(linear))
    assert_operator (hue(read(fitted)) - wanted).abs, :<, (hue(read(clipped)) - wanted).abs
  end

  def test_headroom_spends_brightness_before_colour
    over = pixel(1.4, 1.1, 0.7)
    dark = read(Emulsion::Gamut.fit(over, 1.5))
    flat = read(Emulsion::Gamut.fit(over, 0.0))
    assert_operator dark.sum, :<, flat.sum, "the pixel is darkened rather than eased toward grey"
# Brightness is spent first, so the colour moves less than when there is
# no brightness to spend.
before = read(Emulsion::Colour.to_linear(over))
with = read(Emulsion::Colour.to_linear(Emulsion::Gamut.fit(over, 1.5)))
without = read(Emulsion::Colour.to_linear(Emulsion::Gamut.fit(over, 0.0)))
wanted = before[2] / before[0]
assert_operator (with[2] / with[0] - wanted).abs, :<, (without[2] / without[0] - wanted).abs
  end

  def test_what_is_still_over_comes_out_of_chroma
    linear = Emulsion::Colour.to_linear(pixel(2.0, 1.2, 0.4))
    out = read(Emulsion::Gamut.desaturate(linear))
    assert_operator out.max, :<=, 1.0 + 1e-6
    assert_operator out[2], :>, read(linear)[2], "the weak channel comes up as the strong one comes down"
  end
end
