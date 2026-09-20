require_relative "test_helper"

class LostColourTest < Minitest::Test
  NEUTRAL = Array.new(Emulsion::ColourBalance::TONES.size) { [0.0, 0.0] }

  # A frame of three patches at one brightness: a grey, a mild yellow whose
  # blue still says something, and a yellow whose blue has fallen away.
  def patches(blue_short: 4.0)
    TestImages.linear_image(90, 30) do |x, _|
      base = 0.30
      case x / 30
      when 0 then [base, base, base]
      when 1 then [base * 1.2, base, base * 2**-1.0]
      else [base * 1.2, base, base * 2**-blue_short]
      end
    end
  end

  def stops(image, column)
    px = TestImages.mean_pixel(image, column * 30 + 8, 8, 14, 14)
    [Math.log2(px[0] / px[1]), Math.log2(px[2] / px[1])]
  end

  def test_zero_amount_changes_nothing
    frame = patches
    assert_operator (Emulsion::LostColour.apply(frame, NEUTRAL, 0.0) - frame).abs.max, :<, 1e-6
  end

  def test_a_grey_stays_grey
    out = Emulsion::LostColour.apply(patches, NEUTRAL, 1.0)
    red, blue = stops(out, 0)
    assert_in_delta 0.0, red, 0.02
    assert_in_delta 0.0, blue, 0.02
  end

  # The point of the whole thing: colour survives where blue does, and eases
  # away where it does not.
  def test_it_eases_only_what_has_lost_its_blue
    before = patches
    after = Emulsion::LostColour.apply(before, NEUTRAL, 1.0)
    mild_before = stops(before, 1)[1].abs
    mild_after = stops(after, 1)[1].abs
    gone_before = stops(before, 2)[1].abs
    gone_after = stops(after, 2)[1].abs

    assert_in_delta mild_before, mild_after, 0.1, "a believable yellow keeps its colour"
    assert_operator gone_after, :<, gone_before * 0.7, "a hopeless one eases toward grey"
  end

  def test_easing_grows_with_how_far_blue_has_fallen
    gone = ->(short) { stops(Emulsion::LostColour.apply(patches(blue_short: short), NEUTRAL, 1.0), 2)[1].abs }
    assert_operator gone.(5.0) / 5.0, :<, gone.(2.0) / 2.0
  end

  def test_the_lost_weight_runs_from_nothing_to_everything
    frame = patches
    linear = Emulsion::Colour.to_linear(frame)
    luma = (linear * Emulsion::LostColour::LUMA).bandmean * 3.0
    lost = Emulsion::LostColour.lost(linear, luma, NEUTRAL)
    assert_in_delta 0.0, lost.extract_area(8, 8, 14, 14).avg, 0.01, "a grey has lost nothing"
    assert_operator lost.extract_area(68, 8, 14, 14).avg, :>, 0.9, "a dead blue is fully lost"
  end
end
