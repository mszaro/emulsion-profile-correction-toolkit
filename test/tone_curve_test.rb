require_relative "test_helper"

class ToneCurveTest < Minitest::Test
  SUPERIA = [0.007, 0.030, 0.055, 0.198, 0.484, 0.741, 0.908, 0.944, 0.989].freeze
  # Phoenix 49605 as scanned: midtones pushed up, highlights bunched at the top.
  BUNCHED = [0.02, 0.10, 0.18, 0.46, 0.77, 0.91, 0.96, 0.975, 0.995].freeze

  def test_matching_shapes_change_nothing
    curve = Emulsion::ToneCurve.new(SUPERIA, SUPERIA)
    [0.0, 0.1, 0.5, 0.9, 1.0].each { |x| assert_in_delta x, curve.at(x), 1e-9 }
  end

  def test_curve_is_monotone_and_keeps_its_ends
    curve = Emulsion::ToneCurve.new(BUNCHED, SUPERIA)
    values = (0..200).map { |i| curve.at(i / 200.0) }
    assert_in_delta 0.0, values.first, 1e-9
    assert_in_delta 1.0, values.last, 1e-9
    values.each_cons(2) { |a, b| assert_operator b, :>=, a - 1e-12 }
  end

  def test_bunched_midtones_come_down
    curve = Emulsion::ToneCurve.new(BUNCHED, SUPERIA)
    assert_operator curve.at(0.77), :<, 0.65
  end

  def test_slope_limits_hold_back_the_strength
    curve = Emulsion::ToneCurve.new(BUNCHED, SUPERIA)
    assert_operator curve.effective_strength, :<, 1.0
    slopes = (0..255).map { |i| (curve.at((i + 1) / 256.0) - curve.at(i / 256.0)) * 256 }
    assert_operator slopes.max, :<=, Emulsion::ToneCurve::MAX_SLOPE + 0.05
    assert_operator slopes.min, :>=, Emulsion::ToneCurve::MIN_SLOPE - 0.05
  end

  def test_zero_strength_is_no_change
    curve = Emulsion::ToneCurve.new(BUNCHED, SUPERIA)
    curve.strength = 0.0
    assert_in_delta 0.4, curve.at(0.4), 1e-9
  end

  def test_image_keeps_its_colour_ratios_and_follows_the_curve_in_brightness
    curve = Emulsion::ToneCurve.new(BUNCHED, SUPERIA)
    image = TestImages.linear_image(64, 1) do |x, _|
      y = Emulsion::Colour.srgb_to_linear_scalar((x + 0.5) / 64.0)
      [y * 1.3, y, y * 0.7]
    end
    out = curve.apply(image)
    [8, 24, 40, 56].each do |x|
      before = image.getpoint(x, 0)
      after = out.getpoint(x, 0)
      luma = ->(px) { px[0] * 0.2126 + px[1] * 0.7152 + px[2] * 0.0722 }
      assert_in_delta curve.at(luma.(before)), luma.(after), 3e-3
      assert_in_delta before[0] / before[1], after[0] / after[1], 0.02
      assert_in_delta before[2] / before[1], after[2] / after[1], 0.02
    end
  end

  def test_shape_is_measured_within_each_frames_stretch
    y = (0..999).map { |i| 40.0 + i * 0.1 }
    sample = Emulsion::RollSample::Pixels.new(r: y, g: y, b: y, y: y, frame_sizes: [1000])
    shape = Emulsion::ToneCurve.shape_of(sample)
    assert_in_delta 0.5, shape[Emulsion::ToneCurve::QUANTILES.index(50)], 0.01
    assert_in_delta 0.25, shape[Emulsion::ToneCurve::QUANTILES.index(25)], 0.01
  end
end
