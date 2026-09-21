require_relative "test_helper"

class FlatFieldTest < Minitest::Test
  WIDTH = 320
  HEIGHT = 240
  FALLOFF = [0.45, 0.6, 0.55].freeze

  # Frames whose subjects differ but which all lose the same light toward the
  # corners, which is the situation the fit is there to see through.
  def roll(dir, falloff: FALLOFF, frames: 14)
    frames.times.map do |n|
      noise = Random.new(n)
      # Subjects in patches of no particular shape, so that nothing about them
      # lines up with distance from the centre.
      patches = Hash.new { |h, k| h[k] = 0.15 + noise.rand * 0.7 }
      half_diagonal = Math.sqrt(WIDTH**2 + HEIGHT**2) / 2.0
      image = TestImages.linear_image(WIDTH, HEIGHT) do |x, y|
        dx = x - WIDTH / 2.0
        dy = y - HEIGHT / 2.0
        r = Math.sqrt(dx * dx + dy * dy) / half_diagonal
        subject = patches[[x / 6, y / 6]]
        falloff.map { |corner| (subject * (1.0 - (1.0 - corner) * r * r)).clamp(0.0, 1.0) }
      end
      path = File.join(dir, format("%03d.png", n))
      (image * 255).cast(:uchar).pngsave(path)
      path
    end
  end

  def test_fit_finds_the_falloff_each_channel_lost
    Dir.mktmpdir do |dir|
      fit = Emulsion::FlatField.fit(roll(dir), verbose: false)
      refute fit.flat?
      FALLOFF.each_with_index do |corner, channel|
        # Read a little in from the very corner, where the curve is still
        # trusted, so a touch less falloff than the corner itself.
        expected = 1.0 - (1.0 - corner) * fit.limit**2
        assert_in_delta expected, fit.corners[channel], 0.08, "channel #{channel}"
      end
    end
  end

  def test_an_even_roll_is_left_alone
    Dir.mktmpdir do |dir|
      fit = Emulsion::FlatField.fit(roll(dir, falloff: [1.0, 1.0, 1.0]), verbose: false)
      assert fit.flat?, "an even roll should not be lifted: #{fit.corners.inspect}"
      image = TestImages.linear_image(64, 48) { |_x, _y| [0.3, 0.3, 0.3] }
      assert_equal image, fit.apply(image)
    end
  end

  def test_applying_the_fit_evens_out_a_frame
    Dir.mktmpdir do |dir|
      paths = roll(dir)
      fit = Emulsion::FlatField.fit(paths, verbose: false)
      frame = Emulsion::Colour.load(paths.first)
      lifted = fit.apply(frame)
      corner = ->(image) { TestImages.mean_pixel(image, 4, 4, 24, 24).sum }
      middle = ->(image) { TestImages.mean_pixel(image, WIDTH / 2 - 12, HEIGHT / 2 - 12, 24, 24).sum }

      assert_operator corner.(lifted) / middle.(lifted), :>,
                      corner.(frame) / middle.(frame) * 1.3
    end
  end

  def test_strength_scales_the_lift
    Dir.mktmpdir do |dir|
      paths = roll(dir)
      fit = Emulsion::FlatField.fit(paths, verbose: false)
      frame = Emulsion::Colour.load(paths.first)
      corner = ->(image) { TestImages.mean_pixel(image, 4, 4, 24, 24).sum }
      full = corner.(fit.apply(frame))

      fit.strength = 0.0
      assert_operator (fit.apply(frame) - frame).abs.max, :<, 1e-3
      fit.strength = 0.5
      half = corner.(fit.apply(frame))
      assert_operator half, :>, corner.(frame)
      assert_operator half, :<, full
    end
  end

  # A corner lifted in steps would show as rings in a clear sky.
  def test_the_lift_has_no_steps_in_it
    Dir.mktmpdir do |dir|
      fit = Emulsion::FlatField.fit(roll(dir), verbose: false)
      sky = TestImages.linear_image(200, 200) { |_x, _y| [0.25, 0.3, 0.45] }
      lifted = fit.apply(sky)
      row = (0...200).map { |x| lifted.getpoint(x, 100)[1] }
      steps = row.each_cons(2).map { |a, b| (b - a).abs }
      assert_operator steps.max, :<, 0.004, "a ring would show as a step along the row"
    end
  end

  # A channel reading far more falloff than the others is reading its own
  # crushed floor, and lifting it that far paints a coloured ring on every
  # frame. It is held to within TINT_LIMIT of what the three do together.
  def test_one_channel_cannot_run_away_from_the_others
    fit = Emulsion::FlatField.new([[1.0, -0.8, 0.0], [1.0, -0.3, 0.0], [1.0, -0.2, 0.0]])
    frame = TestImages.linear_image(WIDTH, HEIGHT) { |_x, _y| [0.2, 0.2, 0.2] }
    corner = TestImages.stops(TestImages.mean_pixel(fit.apply(frame), 2, 2, 10, 10))
    assert_operator corner[1].abs, :<=, 2 * Emulsion::FlatField::TINT_LIMIT + 0.05
    assert_operator corner[0].abs, :<=, 2 * Emulsion::FlatField::TINT_LIMIT + 0.05
  end
end
