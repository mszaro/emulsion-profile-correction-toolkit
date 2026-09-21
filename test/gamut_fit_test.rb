require_relative "test_helper"

class GamutFitTest < Minitest::Test
  # A roll's pixels in 0..255, colour pointing in every direction when `hues`
  # is the full circle and bunched when it is a slice of it.
  def sample(hues: 2 * Math::PI, count: 8000, seed: 4)
    noise = Random.new(seed)
    r = []
    g = []
    b = []
    count.times do
      level = 60 + noise.rand * 120
      angle = noise.rand * hues
      reach = 10 + noise.rand * 40
      r << (level + reach * Math.cos(angle)).clamp(1.0, 254.0)
      g << level
      b << (level + reach * Math.sin(angle)).clamp(1.0, 254.0)
    end
    y = r.each_index.map { |i| 0.2126 * r[i] + 0.7152 * g[i] + 0.0722 * b[i] }
    Emulsion::RollSample::Pixels.new(r: r, g: g, b: b, y: y, frame_sizes: [count])
  end

  # The reference must be a no op: a roll already as spread as healthy looks
  # has nothing to reopen.
  def test_a_roll_at_the_healthy_spread_is_left_alone
    roll = sample
    spread = Emulsion::GamutFit.new(roll, healthy_spread: 0.0, verbose: false).spread_before
    fit = Emulsion::GamutFit.new(roll, healthy_spread: spread, verbose: false)
    fit.gains.flatten.each { |gain| assert_in_delta 1.0, gain, 0.02 }
  end

  def test_a_squashed_roll_is_reopened_toward_the_healthy_spread
    fit = Emulsion::GamutFit.new(sample(hues: Math::PI / 2), healthy_spread: 0.9, verbose: false)
    assert_operator fit.spread_after, :>, fit.spread_before
  end

  def test_the_reference_carries_a_healthy_spread
    reference = Emulsion::Reference.load("fujifilm-superia")
    refute_nil reference.healthy_spread
    assert_operator reference.healthy_spread, :>, 0.2
    assert_operator reference.healthy_spread, :<, 0.9
  end
end
