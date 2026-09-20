require_relative "test_helper"
require_relative "../lib/emulsion/detail"

class DetailTest < Minitest::Test
  SIZE = 320

  # Softness is read in pixels of a whole frame, so these plates stand in for a
  # frame reduced to 320 pixels: a blur of a pixel here is a soft frame, and
  # three is a frame that moved.
  SOFT = 1.3
  RUINED = 3.0

  # A plate of linear values, blurred as a lens or a shaken camera would, with
  # grain laid on afterwards in display terms as a scan carries it.
  def plate(blur: 0.0, grain: 0.0, seed: 5, width: SIZE, height: SIZE)
    frame = TestImages.linear_image(width, height) do |x, y|
      value = yield(x, y)
      [value, value, value]
    end
    frame = frame.gaussblur(blur) if blur.positive?
    if grain.positive?
      frame += Vips::Image.gaussnoise(width, height, mean: 0, sigma: grain, seed: seed)
    end
    Emulsion::Colour.clamp01(frame).copy_memory
  end

  def step(width: SIZE, height: SIZE, **options)
    plate(width: width, height: height, **options) { |x, _| x < width / 2 ? 0.05 : 0.45 }
  end

  # Squares, so that both axes have edges of their own to be judged by.
  def grid(**options)
    plate(**options) { |x, y| (x / 24) % 2 == (y / 24) % 2 ? 0.08 : 0.38 }
  end

  def luma_values(band)
    band.write_to_memory.unpack("f*").each_slice(band.bands)
        .map { |px| Emulsion::Measurements::LUMA.zip(px).sum { |weight, v| weight * v } }
  end

  # Profiles averaged along the edge, so grain does not set the answer.
  def across(frame, top, height)
    luma_values(frame.extract_area(0, top, frame.width, height).shrink(1, height))
  end

  def down(frame, left, width)
    luma_values(frame.extract_area(left, 0, width, frame.height).shrink(width, 1))
  end

  def slope_of(values)
    values.each_cons(2).map { |a, b| (b - a).abs }.max
  end

  def test_flat_grain_is_not_worth_sharpening
    grainy = plate(grain: 0.03) { 0.18 }
    measured = Emulsion::Detail.measure(grainy)

    assert_operator measured.grain, :>, 0.01, "the grain itself should be found"
    assert_operator measured.edge, :<, Emulsion::Detail::MIN_EDGE
    refute measured.sharpenable, "grain on its own is not detail"
    assert_same grainy, Emulsion::Detail.sharpen(grainy, measured, 1.0)
  end

  def test_grain_follows_how_much_noise_the_frame_carries
    quiet = Emulsion::Detail.measure(plate(grain: 0.01) { 0.18 }).grain
    loud = Emulsion::Detail.measure(plate(grain: 0.03) { 0.18 }).grain

    assert_in_delta 3.0, loud / quiet, 0.4
    assert_operator Emulsion::Detail.measure(plate { 0.18 }).grain, :<, 1e-4
  end

  # Grain is everywhere and detail is not, so the two should not be confused
  # even when the grainy frame is the sharper of the two.
  def test_grain_is_told_apart_from_detail
    grainy_flat = Emulsion::Detail.measure(plate(grain: 0.03) { 0.18 })
    clean_edges = Emulsion::Detail.measure(grid(grain: 0.004))

    assert_operator grainy_flat.grain, :>, clean_edges.grain
    assert_operator clean_edges.edge, :>, grainy_flat.edge * 20
    assert clean_edges.sharpenable
    refute grainy_flat.sharpenable
  end

  def test_a_soft_edge_is_sharpenable_and_comes_back_steeper
    frame = step(blur: SOFT, grain: 0.006)
    measured = Emulsion::Detail.measure(frame)

    assert measured.sharpenable, "a soft frame with a real edge in it is worth sharpening"
    assert_operator measured.blur, :>, 1.0
    assert_operator measured.radius, :>, 1.0, "the radius should follow the softness"

    sharpened = Emulsion::Detail.sharpen(frame, measured, 1.0)
    assert_operator slope_of(across(sharpened, 40, 240)), :>,
                    slope_of(across(frame, 40, 240)) * 1.15
  end

  def test_softness_follows_how_far_the_frame_is_blurred
    blurs = [0.8, SOFT, 2.0].map { |b| Emulsion::Detail.measure(step(blur: b, grain: 0.006)).blur }

    assert_operator blurs[0], :<, blurs[1]
    assert_operator blurs[1], :<, blurs[2]
  end

  def test_a_frame_blurred_past_recovery_is_left_alone
    frame = step(blur: RUINED, grain: 0.006)
    measured = Emulsion::Detail.measure(frame)

    assert_operator measured.blur, :>, Emulsion::Detail::MAX_BLUR * Emulsion::Detail::MIN_SIGMA
    refute measured.sharpenable, "there is no edge left in this frame to recover"
    assert_same frame, Emulsion::Detail.sharpen(frame, measured, 1.0)
  end

  # A frame smeared sideways keeps its horizontal edges, which is why each axis
  # is judged on its own.
  def test_a_sideways_smear_is_not_read_as_a_sharp_frame
    sharp = grid(grain: 0.006)
    smear = Vips::Image.new_from_array([Array.new(13, 1.0)], 13.0)
    smeared = sharp.conv(smear, precision: :float).copy_memory
    measured = Emulsion::Detail.measure(smeared)

    assert_operator measured.blur, :>, Emulsion::Detail.measure(sharp).blur + 1.0
    refute measured.sharpenable
    assert_same smeared, Emulsion::Detail.sharpen(smeared, measured, 1.0)
  end

  def test_sharpening_leaves_a_grey_ramp_grey
    ramp = plate(grain: 0.006) do |x, y|
      tone = 0.02 + 0.6 * ((x / 32) / 9.0)
      (y / 20) % 2 == 0 ? tone : tone * 0.55
    end
    measured = Emulsion::Detail.measure(ramp)
    assert measured.sharpenable

    sharpened = Emulsion::Detail.sharpen(ramp, measured, 1.0)
    assert_operator (sharpened - ramp).abs.max, :>, 1e-3, "the ramp should have been sharpened"
    assert_operator (sharpened[0] - sharpened[1]).abs.max, :<, 1e-6
    assert_operator (sharpened[2] - sharpened[1]).abs.max, :<, 1e-6
  end

  def test_no_amount_is_no_change
    frame = step(blur: SOFT, grain: 0.006)
    measured = Emulsion::Detail.measure(frame)

    assert measured.sharpenable
    assert_same frame, Emulsion::Detail.sharpen(frame, measured, 0.0)
    assert_same frame, Emulsion::Detail.sharpen(frame, measured, -1.0)
  end

  def test_amount_scales_the_effect
    frame = step(blur: SOFT, grain: 0.006)
    measured = Emulsion::Detail.measure(frame)
    slopes = [0.3, 1.0].map do |amount|
      slope_of(across(Emulsion::Detail.sharpen(frame, measured, amount), 40, 240))
    end

    assert_operator slope_of(across(frame, 40, 240)), :<, slopes[0]
    assert_operator slopes[0], :<, slopes[1]
  end

  # Flat grain on one side, a soft edge on the other, in one frame.
  def test_flat_grain_is_held_back_while_the_edge_is_sharpened
    frame = plate(blur: SOFT, grain: 0.02) do |x, _|
      x < SIZE / 2 ? 0.18 : (x < SIZE * 3 / 4 ? 0.05 : 0.45)
    end
    measured = Emulsion::Detail.measure(frame)
    assert measured.sharpenable

    sharpened = Emulsion::Detail.sharpen(frame, measured, 1.0)
    flat = ->(image) { image.extract_area(20, 20, SIZE / 2 - 40, SIZE - 40).deviate }
    assert_operator flat.(sharpened) / flat.(frame), :<, 1.1, "flat grain should stay flat"

    edge = ->(image) { slope_of(across(image, 40, 240)) }
    assert_operator edge.(sharpened), :>, edge.(frame) * 1.15
  end

  # The same step twice, once in the midtones and once up against white.
  def test_the_effect_tapers_off_toward_white
    tones = ->(v) { Emulsion::Colour.srgb_to_linear_scalar(v) }
    frame = plate(blur: 1.0, grain: 0.004) do |x, y|
      dark = (y / 24) % 2 == 0
      x < SIZE / 2 ? tones.(dark ? 0.35 : 0.50) : tones.(dark ? 0.82 : 0.97)
    end
    measured = Emulsion::Detail.measure(frame)
    assert measured.sharpenable

    sharpened = Emulsion::Detail.sharpen(frame, measured, 1.0)
    swing = lambda do |image, left|
      values = down(image, left, 100)
      values.max - values.min
    end
    midtones = swing.(sharpened, 40) / swing.(frame, 40)
    highlights = swing.(sharpened, SIZE / 2 + 40) / swing.(frame, SIZE / 2 + 40)

    assert_operator midtones, :>, 1.10
    assert_operator highlights, :<, 1.0 + (midtones - 1.0) * 0.75
  end

  def test_a_frame_too_small_to_tile_is_left_alone
    tiny = plate(width: 12, height: 12) { 0.2 }
    measured = Emulsion::Detail.measure(tiny)

    refute measured.sharpenable
    assert_same tiny, Emulsion::Detail.sharpen(tiny, measured, 1.0)
  end
end
