require_relative "test_helper"

class SkyTest < Minitest::Test
  W = 200
  H = 150
  SKY = (H * 0.45).to_i

  # A frame with a smooth bright top and a busy bottom, which is the shape of
  # every outdoor photograph the detector is meant to fire on.
  def frame(sky: [0.30, 0.34, 0.45], ground: 0.12, sky_from: 0, noise: 0.0)
    wobble = Random.new(3)
    TestImages.linear_image(W, H) do |x, y|
      if y >= sky_from && y < SKY
        drift = noise.zero? ? 0.0 : wobble.rand(-noise..noise)
        [sky[0], sky[1], sky[2] * 2**drift]
      else
        busy = ((x / 3) + (y / 3)) % 2 == 0 ? 1.6 : 0.5
        [ground * busy, ground * busy * 0.95, ground * busy * 0.9]
      end
    end
  end

  def test_it_finds_a_plain_sky
    mask = Emulsion::Sky.mask(frame)
    refute_nil mask
    assert_in_delta 1.0, mask.extract_area(10, 10, W - 20, SKY - 20).avg, 0.05, "the sky is inside"
    assert_in_delta 0.0, mask.extract_area(10, SKY + 20, W - 20, 20).avg, 0.05, "the ground is not"
  end

  def test_a_frame_with_no_smooth_bright_region_has_no_sky
    assert_nil Emulsion::Sky.mask(frame(sky: [0.12, 0.12, 0.12]))
  end

  def test_a_dark_frame_has_no_sky
    assert_nil Emulsion::Sky.mask(frame(sky: [0.06, 0.07, 0.09], ground: 0.02))
  end

  # A lit wall in the middle of a frame is not a sky, however smooth it is.
  def test_a_bright_region_that_does_not_reach_the_top_is_refused
    assert_nil Emulsion::Sky.mask(frame(sky_from: (H * 0.2).to_i))
  end

  # A room full of lamps passes brightness and flatness and fails this.
  def test_a_region_whose_colour_wanders_is_refused
    assert_nil Emulsion::Sky.mask(frame(noise: 0.9))
  end

  # The case the whole thing exists for: a sky that has gone yellow is still
  # a sky, and nothing here may key on its colour.
  def test_a_yellow_sky_is_still_found
    refute_nil Emulsion::Sky.mask(frame(sky: [0.42, 0.38, 0.22]))
  end

  def sky_stops(image, mask)
    share = mask.avg
    linear = Emulsion::Colour.to_linear(image)
    v = (0..2).map { |c| (linear[c] * mask).avg / share }
    [Math.log2(v[0] / v[1]), Math.log2(v[2] / v[1])]
  end

  # A sky may be any blue it likes, so a blue one is left exactly alone.
  def test_a_blue_sky_is_left_alone
    frame = frame(sky: [0.24, 0.30, 0.52])
    mask = Emulsion::Sky.mask(frame)
    refute_nil mask
    assert_operator (Emulsion::Sky.level(frame, mask, 0.75) - frame).abs.max, :<, 1e-6
  end

  def test_a_warm_sky_is_brought_back_to_neutral
    frame = frame(sky: [0.42, 0.38, 0.22])
    mask = Emulsion::Sky.mask(frame)
    before = sky_stops(frame, mask)
    after = sky_stops(Emulsion::Sky.level(frame, mask, 0.75), mask)
    assert_operator before[1], :<, -0.5, "it started warm"
    assert_in_delta 0.0, after[1], 0.08, "and lands at neutral"
    assert_operator after[0], :<=, 0.05, "with red no higher than green"
  end

  def test_it_moves_no_further_than_the_cap
    frame = frame(sky: [0.55, 0.40, 0.10])
    mask = Emulsion::Sky.mask(frame)
    before = sky_stops(frame, mask)
    after = sky_stops(Emulsion::Sky.level(frame, mask, 0.4), mask)
    assert_operator after[1] - before[1], :<=, 0.45
  end

  def test_no_sky_means_no_change
    frame = frame(sky: [0.42, 0.38, 0.22])
    assert_operator (Emulsion::Sky.level(frame, nil, 0.75) - frame).abs.max, :<, 1e-6
    assert_operator (Emulsion::Sky.level(frame, Emulsion::Sky.mask(frame), 0.0) - frame).abs.max, :<, 1e-6
  end

  # The ground is not the sky, and the correction stays off it.
  def test_the_ground_keeps_its_colour
    frame = frame(sky: [0.42, 0.38, 0.22])
    levelled = Emulsion::Sky.level(frame, Emulsion::Sky.mask(frame), 0.75)
    patch = [10, H - 20, W - 20, 10]
    assert_operator (levelled.extract_area(*patch) - frame.extract_area(*patch)).abs.max, :<, 0.02
  end
end
