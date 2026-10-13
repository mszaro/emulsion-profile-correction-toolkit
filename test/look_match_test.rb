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

  # The shadows of an ordinary frame keep their colour however the rest of
  # the frame moves.
  def test_deep_shadows_keep_their_colour
    look = FilmScan::LookMatch.fit(lab_pixels(0, 12), lab_pixels(0, -4, seed: 2))
    frame = srgb_from(Array.new(500) { [50.0, 0.0, 12.0] } + Array.new(100) { [8.0, 0.0, 10.0] })
    after = look.apply(frame)
    shadows = FilmScan::LookMatch.pixels(after.extract_area(0, 5, 100, 1), 100, weighted: false)
    assert_in_delta 10.0, shadows.sum { |px| px[2] } / shadows.size, 1.0
    assert_operator mean_of(after, 2), :<, 4.0, "the midtones should still move"
  end

  # A dark scene, such as a church interior with lit windows, keeps its own
  # look entirely: lifting it would only grey the dark and blow the windows.
  def test_a_very_dark_frame_keeps_its_own_look
    look = FilmScan::LookMatch.fit(lab_pixels(-10, 12), lab_pixels(5, -3, seed: 2))
    frame = srgb_from(Array.new(540) { [6.0, 2.0, 4.0] } + Array.new(60) { [70.0, 10.0, 30.0] })
    assert_equal 0.0, (look.apply(frame) - frame).abs.max
  end

  # A sky says nothing about how either film renders, so its colour is left
  # out of the fit, but its lightness still counts.
  def test_sky_counts_for_lightness_but_not_for_colour
    rng = Random.new(3)
    ground = ->(yellow) { Array.new(1200) { [50.0 + rng.rand * 10, rng.rand * 8 - 4, yellow + rng.rand * 8 - 4] } }
    frame = srgb_from(Array.new(1200) { [55.0 + rng.rand * 5, -5.0, -40.0] } + ground.call(0.0))
    sky = Vips::Image.black(100, 24).draw_rect(1.0, 0, 0, 100, 12, fill: true).cast(:float)
    target = FilmScan::LookMatch.pixels(frame, 2400, weighted: false, sky: sky)
    assert_equal 1200, target.count { |px| FilmScan::LookMatch.sky?(px) }

    film = ground.call(10.0)
    after = FilmScan::LookMatch.fit(film, target).apply(srgb_from(film))
    assert_in_delta 0.0, mean_of(after, 2), 1.5, "the ground should match the ground, not the blue sky"
  end

  def test_survives_the_cache
    film = lab_pixels(-10, 12)
    look = FilmScan::LookMatch.fit(film, lab_pixels(5, -3, seed: 2))
    copy = FilmScan::LookMatch.from_cache(YAML.safe_load(YAML.dump(look.to_h), symbolize_names: true))
    frame = srgb_from(film)
    assert_operator (look.apply(frame) - copy.apply(frame)).abs.max, :<, 1e-6
  end
end
