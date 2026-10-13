require_relative "test_helper"

class MonochromeTest < Minitest::Test
  # A flat black and white frame the lab scanned in colour, a little warm.
  def tinted_flat_frame
    TestImages.linear_image(160, 120) do |x, y|
      level = 0.08 + 0.12 * (((x / 8) + (y / 8)) % 4) / 3.0
      [level * 1.06, level, level * 0.93]
    end
  end

  def options
    FilmScan::DEFAULTS.merge(FilmScan::Profile.load("black-and-white").settings).merge(fix: [])
  end

  def test_a_tinted_frame_comes_out_neutral_grey
    out = FilmScan::Pipeline.new(options).render(tinted_flat_frame)
    assert_operator (out[0] - out[1]).abs.max, :<, 1e-6
    assert_operator (out[2] - out[1]).abs.max, :<, 1e-6
  end

  def test_a_flat_frame_is_stretched
    frame = tinted_flat_frame
    out = FilmScan::Pipeline.new(options).render(frame)
    assert_operator out[1].max - out[1].min, :>, (frame[1].max - frame[1].min) * 1.5
  end

  def test_a_black_and_white_profile_needs_no_colour_settings
    profile = FilmScan::Profile.load("black-and-white")
    assert profile.settings[:monochrome]
    refute profile.settings.key?(:wb)
  end
end
