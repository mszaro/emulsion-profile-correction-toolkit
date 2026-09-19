require_relative "test_helper"

class ColourBalanceTest < Minitest::Test
  NEUTRAL = Array.new(Emulsion::ColourBalance::TONES.size) { [0.0, 0.0] }

  # A roll of frames whose neutrals, once scanned, have a teal black floor and
  # a blue channel that sags through the midtones, as Lucky and Phoenix do.
  def scanned_roll(frames: 12, per_frame: 4000, seed: 7, sag: 1.35, scene: nil, scene_share: 0.0)
    rng = Random.new(seed)
    r = []
    g = []
    b = []
    y = []
    sizes = []
    floors = [0.0, 25.0, 18.0]
    frames.times do
      per_frame.times do
        luma = Math.exp(rng.rand(Math.log(0.003)..Math.log(0.85)))
        # Most of a scene is near neutral; the rest is coloured in any direction,
        # or, given a scene colour, a share of it is that one colour.
        roll = rng.rand
        tint = if scene && roll < scene_share then scene.map { |s| 2**(s + rng.rand(-0.15..0.15)) }
               elsif roll < 0.6 + scene_share * 0.4 then [1.0, 1.0]
               else [2**rng.rand(-1.2..1.2), 2**rng.rand(-1.2..1.2)]
               end
        true_px = [luma * tint[0], luma, luma * tint[1]]
        scanned = [true_px[0], true_px[1], 0.9 * true_px[2]**sag].each_with_index.map do |v, c|
          encoded = encode(v.clamp(0.0, 1.0)) * 255.0
          floors[c] + encoded * (255.0 - floors[c]) / 255.0
        end
        r << scanned[0]
        g << scanned[1]
        b << scanned[2]
        y << (0.2126 * scanned[0] + 0.7152 * scanned[1] + 0.0722 * scanned[2])
      end
      sizes << per_frame
    end
    Emulsion::RollSample::Pixels.new(r: r, g: g, b: b, y: y, frame_sizes: sizes)
  end

  def encode(v)
    v <= 0.0031308 ? v * 12.92 : 1.055 * (v**(1 / 2.4)) - 0.055
  end

  def test_black_offsets_find_the_raised_floors
    offsets = Emulsion::ColourBalance.black_offsets(scanned_roll(sag: 1.0))
    assert_in_delta 0.0, offsets[0], 0.5
    assert_in_delta 25.0, offsets[1], 4.0
    assert_in_delta 18.0, offsets[2], 4.0
  end

  def test_roll_fit_brings_neutral_back_at_every_tone
    sample = scanned_roll
    before = Emulsion::ColourBalance.neutral_by_tone(
      Emulsion::ColourBalance.linear_pixels(sample, [0, 0, 0])
    ).compact
    assert before.any? { |_, blue| blue.abs > 0.5 }, "the test roll should start with a strong cast"

    balance = Emulsion::ColourBalance.fit_roll(sample, NEUTRAL)
    after = balance.apply_to_sample(sample)
    pixels = Emulsion::ColourBalance.linear_pixels(after, [0, 0, 0])
    Emulsion::ColourBalance.neutral_by_tone(pixels).each_with_index do |pair, i|
      next unless pair

      assert_in_delta 0.0, pair[0], 0.15, "red at tone #{i}"
      assert_in_delta 0.0, pair[1], 0.15, "blue at tone #{i}"
    end
  end

  def test_roll_fit_moves_neutral_to_a_tinted_target
    target = Array.new(Emulsion::ColourBalance::TONES.size) { [0.2, -0.3] }
    balance = Emulsion::ColourBalance.fit_roll(scanned_roll, target)
    pixels = Emulsion::ColourBalance.linear_pixels(balance.apply_to_sample(scanned_roll), [0, 0, 0])
    measured = Emulsion::ColourBalance.neutral_by_tone(pixels).compact
    assert_in_delta 0.2, measured.sum(&:first) / measured.size, 0.1
    assert_in_delta(-0.3, measured.sum(&:last) / measured.size, 0.1)
  end

  # One roll full of warm sandstone, one full of blue sky, both with the same
  # scan cast. Pooled, the fit should find the cast and leave the scenes be.
  def test_film_fit_pools_rolls_so_no_one_scene_sets_the_cast
    warm = scanned_roll(seed: 1, scene: [0.7, -1.4], scene_share: 0.45)
    sky = scanned_roll(seed: 2, scene: [-0.9, 0.9], scene_share: 0.45)
    gains = Emulsion::ColourBalance.fit_film([warm, sky], NEUTRAL)
    [warm, sky].each do |roll|
      balance = Emulsion::ColourBalance.new(Emulsion::ColourBalance.black_offsets(roll), gains)
      pixels = Emulsion::ColourBalance.linear_pixels(balance.apply_to_sample(roll), [0, 0, 0])
      Emulsion::ColourBalance.neutral_by_tone(pixels, from: NEUTRAL).each_with_index do |pair, i|
        next unless pair && i.between?(2, 6)

        assert_in_delta 0.0, pair[1], 0.25, "blue at tone #{i}"
      end
    end
  end

  def test_roll_drift_stays_within_its_limit
    film = Emulsion::ColourBalance.fit_film([scanned_roll], NEUTRAL)
    drifted = scanned_roll(seed: 3, sag: 1.6)
    balance = Emulsion::ColourBalance.fit_roll(drifted, NEUTRAL, film: film, limit: 0.4)
    balance.gains.zip(film).each do |(r, g, b), (fr, fg, fb)|
      assert_operator ((b - g) - (fb - fg)).abs, :<=, 0.45
      assert_operator ((r - g) - (fr - fg)).abs, :<=, 0.45
    end
  end

  def test_gains_keep_a_neutral_at_its_brightness
    gains = Emulsion::ColourBalance.gains_toward([[0.5, -1.0]], [[0.0, 0.0]]).first
    before = [2**0.5, 1.0, 2**-1.0]
    after = before.each_with_index.map { |v, c| v * 2**gains[c] }
    luma = ->(px) { 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2] }
    assert_in_delta luma.(before), luma.(after), 1e-9
    assert_in_delta after[0], after[1], 1e-9
    assert_in_delta after[2], after[1], 1e-9
  end

  def test_zero_strength_leaves_an_image_alone
    balance = Emulsion::ColourBalance.new([0.0, 20.0, 10.0], Array.new(8) { [0.5, 0.0, 1.5] })
    balance.strength = 0.0
    image = TestImages.linear_image(16, 16) { |x, y| [0.02 * (x + 1), 0.03 * (y + 1), 0.25] }
    assert_operator (balance.apply(image) - image).abs.max, :<, 1e-3
  end

  # A frame with a cast of one stop too little blue everywhere, where the
  # brightest band is mostly blue sky. The shift and tilt fit should take the
  # cast out of the greys without letting the sky drag it.
  def test_frame_fit_removes_a_cast_without_greying_the_sky
    width = 240
    height = 200
    image = TestImages.linear_image(width, height) do |x, y|
      px = if x >= 160 && y < 120
             [0.20, 0.40, 0.95]
           else
             luma = Math.exp(Math.log(0.004) + (x % 160) / 159.0 * (Math.log(0.75) - Math.log(0.004)))
             [luma, luma, luma]
           end
      [px[0], px[1], px[2] * 0.5]
    end

    frame = Emulsion::ColourBalance.fit_frame(image, NEUTRAL)
    refute_nil frame
    corrected = frame.apply(image)

    [20, 70, 120].each do |x|
      grey = TestImages.stops(TestImages.mean_pixel(corrected, x, 150, 6, 30))
      assert_in_delta 0.0, grey[1], 0.2, "grey at column #{x} should lose its cast"
    end
    sky = TestImages.stops(TestImages.mean_pixel(corrected, 180, 30, 40, 60))
    assert_operator sky[1], :>, 0.8, "the sky should stay blue"
  end

  # Mostly foliage with a few grey walls and no cast at all: the frame fit
  # should leave the colour alone rather than read the green as a cast.
  def test_frame_fit_leaves_a_frame_of_foliage_alone
    image = TestImages.linear_image(200, 200) do |x, y|
      luma = Math.exp(Math.log(0.004) + x / 199.0 * (Math.log(0.75) - Math.log(0.004)))
      (y % 10) < 7 ? [luma * 0.55, luma * 1.15, luma * 0.45] : [luma, luma, luma]
    end
    frame = Emulsion::ColourBalance.fit_frame(image, NEUTRAL)
    refute_nil frame
    frame.gains.each do |r, g, b|
      assert_operator (r - g).abs, :<, 0.25
      assert_operator (b - g).abs, :<, 0.25
    end
  end

  def test_frame_fit_eases_off_toward_its_limit
    image = TestImages.linear_image(200, 100) do |x, _|
      luma = Math.exp(Math.log(0.004) + x / 199.0 * (Math.log(0.75) - Math.log(0.004)))
      [luma, luma, luma * 0.25]
    end
    full = Emulsion::ColourBalance.fit_frame(image, NEUTRAL)
    held = Emulsion::ColourBalance.fit_frame(image, NEUTRAL, limit: 0.6)
    blue = ->(fit) { fit.gains.map { |_, g, b| b - g }.max }
    assert_in_delta 2.0, blue.(full), 0.35
    assert_operator blue.(held), :<, 0.6
    assert_operator blue.(held), :>, 0.45
  end

  # A tint that is only in the midtones, which a straight line cannot follow.
  def test_residual_gains_follow_a_bump_in_the_midtones
    pixels = []
    2000.times do |i|
      luma = Math.exp(Math.log(0.004) + (i % 100) / 99.0 * (Math.log(0.75) - Math.log(0.004)))
      warm = luma.between?(0.03, 0.25) ? 0.25 : 0.0
      pixels << [luma * 2**warm, luma, luma * 2**(-warm)]
    end
    gains = Emulsion::ColourBalance.residual_gains(pixels, NEUTRAL, 0.6, 50)
    refute_nil gains
    stops = gains.map { |r, g, b| [r - g, b - g] }
    mid = Emulsion::ColourBalance::TONES.index(0.1)
    assert_operator stops[mid][0], :<, -0.15
    assert_operator stops[mid][1], :>, 0.15
    assert_operator stops.last[0].abs, :<, 0.1
  end

  def test_robust_line_ignores_one_outlying_band
    points = (0..7).map { |i| [i.to_f, 1.0, 1.0] }
    points[6] = [6.0, -3.0, 1.0]
    intercept, slope = Emulsion::ColourBalance.robust_line(points)
    assert_in_delta 1.0, intercept + slope * 3.5, 0.2
    assert_operator slope.abs, :<, 0.1
  end

  # A cast that grows steadily toward the highlights is drift, not an outlier.
  def test_robust_line_keeps_a_smooth_tilt
    points = (0..7).map { |i| [i.to_f, 0.4 * i - 1.0, 1.0] }
    intercept, slope = Emulsion::ColourBalance.robust_line(points)
    assert_in_delta 0.4, slope, 0.02
    assert_in_delta(-1.0, intercept, 0.05)
  end
end
