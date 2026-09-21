require_relative "test_helper"

class PipelineVetoesTest < Minitest::Test
  def pipeline(**options)
    Emulsion::Pipeline.new(Emulsion::DEFAULTS.merge(contrast: 0.2, max_stretch: 3.0).merge(options))
  end

  # A frame that needed the whole stretch it was allowed keeps half its
  # contrast; one that did not keeps all of it.
  def test_contrast_is_held_back_on_a_frame_stretched_to_the_limit
    flat = [[0.35, 0.65]] * 3
    open = [[0.0, 1.0]] * 3
    assert_in_delta 0.1, pipeline.send(:contrast_for, flat), 1e-9
    assert_in_delta 0.2, pipeline.send(:contrast_for, open), 1e-9
  end

  def sky_frame
    TestImages.linear_image(200, 150) do |x, y|
      if y < 60
        [0.30, 0.34, 0.45]
      else
        busy = ((x / 3) + (y / 3)) % 2 == 0 ? 1.6 : 0.5
        [0.12 * busy, 0.11 * busy, 0.1 * busy]
      end
    end
  end

  def test_a_frame_with_a_sky_gets_the_sky_headroom
    with_sky = pipeline(highlight_headroom: 0.0, sky_headroom: 1.5)
    assert_equal 1.5, with_sky.send(:headroom_for, sky_frame)
    without = pipeline(highlight_headroom: 0.0, sky_headroom: 1.5)
    ground = TestImages.linear_image(200, 150) { |x, y| [0.1, 0.1, 0.1].map { |v| v * (((x + y) % 7) + 1) / 4.0 } }
    assert_equal 0.0, without.send(:headroom_for, ground)
  end

  def test_the_profile_headroom_wins_when_it_is_larger
    assert_equal 2.0, pipeline(highlight_headroom: 2.0, sky_headroom: 1.5).send(:headroom_for, sky_frame)
  end
  # A dark interior with one lit window: too little of it for the frame fit to
  # read, and so no ground for inferring lost colour either. The window keeps
  # its amber.
  def test_a_frame_the_fit_cannot_read_keeps_its_colour
    frame = TestImages.linear_image(200, 150) do |x, y|
      x.between?(80, 120) && y.between?(50, 90) ? [0.6, 0.42, 0.03] : [0.002, 0.002, 0.002]
    end
    reference = Emulsion::Reference.load("fujifilm-superia")
    assert_nil Emulsion::ColourBalance.fit_frame(frame, reference.neutral)
    options = Emulsion::DEFAULTS.merge(reference: "fujifilm-superia", frame_balance: 1.0,
                                       frame_balance_limit: 2.5, lost_colour: 1.0)
    shaped = Emulsion::Pipeline.new(options, reference: reference).send(:balance, frame)
    assert_operator (shaped - frame).abs.max, :<, 1e-6
  end
end
