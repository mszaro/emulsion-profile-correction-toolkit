require_relative "test_helper"
require_relative "../lib/emulsion/dynamics"

class DynamicsTest < Minitest::Test
  D = Emulsion::Dynamics

  # TestImages describes a frame in linear light. These frames are easier to
  # write down as the display values a scan actually holds, and anything over
  # white is clipped on the way in, as a scanner would. Held in memory, since
  # the frame is read back point by point.
  def display_image(width, height)
    TestImages.linear_image(width, height) do |x, y|
      yield(x, y).map { |v| Emulsion::Colour.srgb_to_linear_scalar([v, 1.0].min) }
    end.copy_memory
  end

  # A crushed side and a bright side, with fine texture through both.
  def contrasty_frame
    display_image(256, 192) do |x, y|
      texture = 0.012 * Math.sin(x / 3.0) * Math.cos(y / 4.0)
      v = (x < 128 ? 0.055 : 0.90) + texture
      [v, v, v]
    end
  end

  # Nothing near either end: a subject lit evenly, with a little of the frame
  # in shade and a little of it catching the light.
  def even_frame
    display_image(256, 192) do |x, y|
      v = 0.45 + 0.04 * Math.sin(x / 9.0) * Math.cos(y / 7.0)
      v = 0.10 if x < 21
      v = 0.88 if x > 240
      [v, v, v]
    end
  end

  # A sky brightening across the frame with a mild warm drift, so red clips
  # first and green and blue stay in range the whole way.
  SKY_WIDTH = 256
  SKY_HEIGHT = 160

  def sky_truth(x, y)
    t = x / (SKY_WIDTH - 1).to_f + 0.04 * (y / (SKY_HEIGHT - 1).to_f - 0.5)
    k = 0.72 + 0.70 * t
    [k, k * (0.70 - 0.06 * t), k * (0.62 - 0.07 * t)]
  end

  def clipped_sky
    display_image(SKY_WIDTH, SKY_HEIGHT) { |x, y| sky_truth(x, y) }
  end

  def corrected(image, amount = 1.0)
    D.apply(image, D.measure(image), amount).copy_memory
  end

  # The largest step from one column to the next along a row, which is what a
  # seam would show up as.
  def column_step(image, row)
    strip = image.extract_area(0, row, image.width, 1)
    left = strip.extract_area(0, 0, image.width - 1, 1)
    right = strip.extract_area(1, 0, image.width - 1, 1)
    (right - left).abs.max
  end

  def test_zero_amount_is_the_frame_itself
    image = contrasty_frame
    out = D.apply(image, D.measure(image), 0.0)
    assert_same image, out
  end

  def test_an_evenly_lit_frame_is_barely_touched
    image = even_frame
    measured = D.measure(image)
    assert_operator measured.shadow_room, :<, 0.2
    assert_operator measured.highlight_room, :<, 0.2

    out = corrected(image)
    assert_operator (out - image).abs.max, :<, 0.03
  end

  def test_a_contrasty_frame_opens_its_shadows
    image = contrasty_frame
    measured = D.measure(image)
    assert_operator measured.shadow_room, :>, 0.8

    out = corrected(image)
    # Away from the edge between the two sides, where the base follows the
    # frame rather than smoothing it.
    area = ->(img) { img.extract_area(8, 8, 92, 176)[1] }
    assert_operator area.(out).avg, :>, area.(image).avg * 1.5
    assert_operator area.(out).deviate, :>, area.(image).deviate * 1.5
  end

  def test_a_grey_ramp_keeps_its_colour_ratios
    image = display_image(128, 32) do |x, _|
      v = 0.02 + 0.88 * x / 127.0
      [v * 1.05, v, v * 0.85]
    end
    out = corrected(image)

    moved = 0
    [8, 40, 72, 104, 120].each do |x|
      before = image.getpoint(x, 16)
      after = out.getpoint(x, 16)
      assert_in_delta before[0] / before[1], after[0] / after[1], 0.01
      assert_in_delta before[2] / before[1], after[2] / after[1], 0.01
      moved += 1 if (after[1] - before[1]).abs > 0.02
    end
    assert_operator moved, :>, 0, "the curve never moved the ramp, so nothing was tested"
  end

  def test_a_clipped_patch_gets_its_colour_back
    patch = [1.20, 0.86, 0.75]
    surround = [0.88, 0.63, 0.55]
    image = display_image(200, 200) do |x, y|
      (80..119).cover?(x) && (80..119).cover?(y) ? patch : surround
    end

    measured = D.measure(image)
    assert_operator measured.clipped, :>, 0.01
    out = corrected(image)

    before = image.getpoint(100, 100)
    after = out.getpoint(100, 100)
    truth = patch[1] / patch[0]
    assert_in_delta 0.86, before[1] / before[0], 1e-3, "the patch should arrive with red clipped"
    assert_operator (after[1] / after[0] - truth).abs, :<, (before[1] / before[0] - truth).abs * 0.6

    # The pixels that were never clipped are left where they were.
    assert_in_delta surround[0], out.getpoint(10, 10)[0], 5e-3
  end

  def test_a_clipped_sky_loses_its_colour_shift
    image = clipped_sky
    out = corrected(image)
    row = SKY_HEIGHT / 2

    [200, 230, 250].each do |x|
      truth = sky_truth(x, row)
      before = image.getpoint(x, row)
      after = out.getpoint(x, row)
      target = truth[1] / truth[0]
      assert_in_delta 1.0, before[0], 1e-3, "red should be clipped at x=#{x}"
      assert_operator (after[1] / after[0] - target).abs,
                      :<, (before[1] / before[0] - target).abs * 0.6
    end
  end

  def test_reconstruction_leaves_no_seam_at_the_clipping_threshold
    image = clipped_sky
    out = corrected(image)
    row = SKY_HEIGHT / 2
    assert_operator column_step(out, row), :<=, column_step(image, row) * 1.5
  end

  def test_the_base_curve_is_monotone_and_keeps_its_ends
    lift = D::SHADOW_PUSH
    pull = D::HIGHLIGHT_PULL
    values = (0..512).map { |i| D.curve_at(i / 512.0, lift, pull) }
    assert_in_delta 0.0, values.first, 1e-9
    assert_in_delta 1.0, values.last, 1e-9
    values.each_cons(2) { |a, b| assert_operator b, :>=, a - 1e-12 }
    assert_operator D.curve_at(0.05, lift, pull), :>, 0.05 * 2.0
    assert_operator D.curve_at(0.95, lift, pull), :<, 0.95
  end

  def test_a_contrasty_frame_has_more_room_than_an_even_one
    assert_operator D.measure(contrasty_frame).shadow_room, :>,
                    D.measure(even_frame).shadow_room
  end
end
