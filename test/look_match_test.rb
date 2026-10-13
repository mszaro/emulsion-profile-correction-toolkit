require_relative "test_helper"

class LookMatchTest < Minitest::Test
  # Lab pixels through the middle tones, lighter or darker and with a cast.
  def lab_pixels(light, yellow, count: 6000, seed: 1)
    rng = Random.new(seed)
    Array.new(count) do
      [(rng.rand * 70 + 15 + light).clamp(0.0, 100.0), rng.rand * 16 - 8, yellow + rng.rand * 16 - 8]
    end
  end

  def srgb_from(pixels, width: 100)
    lab = Vips::Image.new_from_memory(pixels.flatten.pack("f*"), width, pixels.size / width, 3, :float)
    FilmScan::Colour.to_srgb(lab.copy(interpretation: :lab).colourspace(:scrgb)).copy(interpretation: :srgb).copy_memory
  end

  def mean_of(srgb, channel, above: 40)
    pixels = FilmScan::LookMatch.pixels(srgb, srgb.width * srgb.height).select { |l, _, _| l > above }
    pixels.sum { |px| px[channel] } / pixels.size
  end

  def test_moves_lightness_and_colour_toward_the_matched_rolls
    film = lab_pixels(-10, 12)
    look = FilmScan::LookMatch.fit(film, lab_pixels(5, -3, seed: 2))
    frame = srgb_from(film)
    after = look.apply(frame)

    assert_in_delta mean_of(frame, 0, above: 0) + 15, mean_of(after, 0, above: 0), 4.0
    assert_in_delta(-3, mean_of(after, 2), 2.5)
  end

  def test_half_strength_goes_half_way
    film = lab_pixels(0, 12)
    look = FilmScan::LookMatch.fit(film, lab_pixels(0, -4, seed: 2))
    look.strength = 0.5
    assert_in_delta 4, mean_of(look.apply(srgb_from(film)), 2), 2.0
  end

  def test_no_strength_leaves_the_frame_alone
    film = lab_pixels(-10, 12)
    look = FilmScan::LookMatch.fit(film, lab_pixels(5, -3, seed: 2))
    look.strength = 0
    frame = srgb_from(film)
    assert_equal 0.0, (look.apply(frame) - frame).abs.max
  end

  # A dark interior has nothing to learn from sunlit streets, so its colour
  # stays where it was however the rest of the roll moves.
  def test_deep_shadows_keep_their_colour
    look = FilmScan::LookMatch.fit(lab_pixels(0, 12), lab_pixels(0, -4, seed: 2))
    dark = srgb_from(Array.new(600) { [8.0, 0.0, 10.0] })
    shifted = FilmScan::LookMatch.pixels(look.apply(dark), 600)
    assert_in_delta 10.0, shifted.sum { |px| px[2] } / shifted.size, 1.0
  end

  def test_survives_the_cache
    film = lab_pixels(-10, 12)
    look = FilmScan::LookMatch.fit(film, lab_pixels(5, -3, seed: 2))
    copy = FilmScan::LookMatch.from_cache(YAML.safe_load(YAML.dump(look.to_h), symbolize_names: true))
    frame = srgb_from(film)
    assert_operator (look.apply(frame) - copy.apply(frame)).abs.max, :<, 1e-6
  end
end
