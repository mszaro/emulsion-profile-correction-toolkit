require_relative "test_helper"

class WarmLightTest < Minitest::Test
  REF = Emulsion::Reference.load("fujifilm-superia")
  WIDTH = 360
  HEIGHT = 240

  # Twilight in a checkerboard of levels. The lamps and what they light run
  # warmer the brighter they are, and the surroundings, lit only by the dusk
  # sky, are blue.
  LEVELS = [0.012, 0.03, 0.07, 0.15, 0.35].freeze

  def level_of(x, y)
    LEVELS[((x / 24) + (y / 24)) % LEVELS.size] * (1.0 + 0.2 * Math.sin(x * 0.9 + y * 1.7))
  end

  def step_of(x, y)
    LEVELS.index { |v| v >= level_of(x, y) / 1.2 } || LEVELS.size - 1
  end

  # Warmth in stops of red against blue, from `dark` at the lowest level to
  # `light` at the highest, with the frame's brightness scaled by `bright`.
  def tilted(dark, light, bright: 1.0)
    TestImages.linear_image(WIDTH, HEIGHT) do |x, y|
      l = [level_of(x, y) * bright, 0.8].min
      warm = dark + (light - dark) * step_of(x, y) / (LEVELS.size - 1.0)
      [l * 2**(warm / 2), l, l * 2**(-warm / 2)]
    end
  end

  # The same scene with every surface grey, under one warm cast.
  def cast
    TestImages.linear_image(WIDTH, HEIGHT) do |x, y|
      l = level_of(x, y)
      [l * 2**0.5, l, l * 2**-0.8]
    end
  end

  def balanced(frame, tilt:, **settings)
    options = Emulsion::DEFAULTS.merge(Emulsion::Profile.load("lucky-shd-400").settings)
                                .merge(chroma_shape: 0.0, lost_colour: 0.0, frame_balance: 1.0, **settings)
    Emulsion::Pipeline.new(options, reference: REF, tilt: tilt).send(:balance, frame)
  end

  # Red against blue across the brightest level, where the lamps are.
  def lamp_warmth(image)
    lit = (0...HEIGHT).flat_map { |y| (0...WIDTH).map { |x| level_of(x, y) > 0.25 ? 1.0 : 0.0 } }
    mask = Vips::Image.new_from_memory(lit.pack("f*"), WIDTH, HEIGHT, 1, :float)
    linear = Emulsion::Colour.to_linear(image)
    Math.log2((linear[0] * mask).avg / (linear[2] * mask).avg)
  end

  def test_lamps_in_a_low_key_frame_keep_their_warmth
    frame = tilted(-0.6, 2.0)
    assert_operator Emulsion::WarmLight.confidence(frame, REF.neutral, 0.0), :>, 0.9
    taken = lamp_warmth(balanced(frame, tilt: 0.0, lamp_guard: 0.0))
    kept = lamp_warmth(balanced(frame, tilt: 0.0))
    assert_operator kept - taken, :>, 0.5, "the guard should leave the lamps warm"
  end

  # A cast warms every tone alike, so there is no tilt to find and the frame
  # balance takes it out as before.
  def test_a_warm_cast_on_a_low_key_frame_is_still_taken_out
    assert_operator Emulsion::WarmLight.confidence(cast, REF.neutral, 0.0), :<, 0.1
    guarded = balanced(cast, tilt: 0.0)
    unguarded = balanced(cast, tilt: 0.0, lamp_guard: 0.0)
    assert_in_delta lamp_warmth(unguarded), lamp_warmth(guarded), 0.05
  end

  # Sunlit stone in daylight also reads bright warm and dark cool, on Lucky
  # especially, and in a bright frame it is left alone.
  def test_a_bright_frame_with_the_same_tilt_is_not_guarded
    frame = tilted(-0.6, 2.0, bright: 3.5)
    assert_operator Emulsion::WarmLight.key_of(frame), :>, 0.5
    assert_equal 0.0, Emulsion::WarmLight.confidence(frame, REF.neutral, 0.0)
  end

  # A dark street shot up at a blown overcast sky is low key and can tilt
  # like lamplight, and the white of the sky gives it away as daylight.
  def test_a_dark_frame_under_a_white_sky_is_not_guarded
    frame = TestImages.linear_image(WIDTH, HEIGHT) do |x, y|
      next [1.0, 1.0, 1.0] if y < HEIGHT / 8

      l = level_of(x, y)
      warm = -0.6 + 2.6 * step_of(x, y) / (LEVELS.size - 1.0)
      [l * 2**(warm / 2), l, l * 2**(-warm / 2)]
    end
    light = Emulsion::WarmLight
    lamplike = light.ramp(light.tilt(frame, REF.neutral), *light::TILT) * light.ramp(light.key_of(frame), *light::KEY)
    assert_operator lamplike, :>, 0.5, "tilt and key alone would read it as lamplight"
    assert_equal 0.0, Emulsion::WarmLight.confidence(frame, REF.neutral, 0.0)
  end

  # Some rolls tilt on every frame, as Phoenix 49605 does, and the tilt is
  # only read against what is typical for the roll.
  def test_a_roll_that_always_tilts_is_not_guarded
    frame = tilted(-0.6, 2.0)
    typical = Emulsion::WarmLight.tilt(frame, REF.neutral)
    assert_equal 0.0, Emulsion::WarmLight.confidence(frame, REF.neutral, typical)
  end

  def test_no_roll_tilt_means_no_guard
    assert_equal 0.0, Emulsion::WarmLight.confidence(tilted(-0.6, 2.0), REF.neutral, nil)
  end

  # Holding back warmth takes off the move along the daylight to tungsten
  # axis and leaves the tint alone, which on Phoenix is real lab drift.
  def test_holding_warmth_leaves_the_tint
    axis = Emulsion::WarmLight::AXIS
    tint = [-axis[1], axis[0]]
    move = (0..1).map { |c| -1.0 * axis[c] + 0.4 * tint[c] }
    fit = Emulsion::ColourBalance.new([0.0, 0.0, 0.0], Array.new(8) { [move[0], 0.0, move[1]] })
    held = Emulsion::WarmLight.hold(fit, 0.5).gains.first
    along = held[0] * axis[0] + held[2] * axis[1]
    across = held[0] * tint[0] + held[2] * tint[1]
    assert_in_delta(-0.5, along, 1e-9)
    assert_in_delta 0.4, across, 1e-9
    assert_equal 0.0, held[1]
  end

  # Warmth is what is kept. A tone the fit warms, such as blue shade under a
  # daylight sky, is warmed as before.
  def test_holding_warmth_leaves_a_warming_move_alone
    move = Emulsion::WarmLight::AXIS.map { |v| v * 0.8 }
    fit = Emulsion::ColourBalance.new([0.0, 0.0, 0.0], Array.new(8) { [move[0], 0.0, move[1]] })
    assert_equal fit.gains, Emulsion::WarmLight.hold(fit, 1.0).gains
  end

  # A frame of leaves reads to the fit as a green cast, and its move toward
  # magenta is capped. The move along the daylight axis is left as it was,
  # and so is a move toward green.
  def test_the_move_toward_magenta_is_capped
  axis = Emulsion::WarmLight::AXIS
  tint = Emulsion::WarmLight::TINT
  gains = [[1.0, -0.3], [-0.5, 0.2]].map do |along_tint, along_axis|
    move = (0..1).map { |c| along_tint * tint[c] + along_axis * axis[c] }
    [move[0], 0.0, move[1]]
  end
  capped = Emulsion::WarmLight.cap_tint(Emulsion::ColourBalance.new([0.0, 0.0, 0.0], gains), 0.4).gains
  project = ->(g, dir) { g[0] * dir[0] + g[2] * dir[1] }
  assert_in_delta 0.4, project.(capped[0], tint), 1e-9
  assert_in_delta(-0.3, project.(capped[0], axis), 1e-9)
  assert_in_delta(-0.5, project.(capped[1], tint), 1e-9)
  assert_in_delta 0.2, project.(capped[1], axis), 1e-9
  end

  # Golden hour in sunlight cannot be found, so a frame's override asks for
  # its warmth to be kept.
  def test_keep_warmth_leaves_a_share_of_a_warm_cast
    taken = lamp_warmth(balanced(cast, tilt: nil))
    kept = lamp_warmth(balanced(cast, tilt: nil, keep_warmth: 0.5))
    assert_operator kept - taken, :>, 0.3
  end
end
