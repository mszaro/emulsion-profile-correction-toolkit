require_relative "test_helper"

class ChromaMapTest < Minitest::Test
  # Pixels whose colour spreads around a centre, as a roll's would.
  def cloud(centre:, spread:, seed: 5, count: 6000)
    noise = Random.new(seed)
    count.times.map do
      luma = 0.05 + noise.rand * 0.35
      [luma * 2**(centre[0] + noise.rand(-spread[0]..spread[0])),
       luma,
       luma * 2**(centre[1] + noise.rand(-spread[1]..spread[1]))]
    end
  end

  # A per-pixel lost weight, in the float the pipeline hands over.
  def weight(value)
    Vips::Image.black(32, 32).cast(:float).new_from_image(value)
  end

  def test_fit_finds_the_stretch_between_two_clouds
    film = cloud(centre: [0.4, -1.2], spread: [0.5, 1.2])
    reference = cloud(centre: [-0.2, 0.1], spread: [0.5, 0.6], seed: 9)
    map = Emulsion::ChromaMap.fit(film, reference)
    refute_nil map
    assert_operator map.matrix[1], :<, 0.9, "blue spread should be pulled in"
    assert_operator map.offset[1], :>, 0.3, "and its centre moved up"
  end

  def test_too_few_pixels_fits_nothing
    assert_nil Emulsion::ChromaMap.fit(cloud(centre: [0, 0], spread: [0.2, 0.2], count: 100),
                                       cloud(centre: [0, 0], spread: [0.2, 0.2], count: 100))
  end

  def test_zero_strength_changes_nothing
    map = Emulsion::ChromaMap.new([0.6, 0.6], [0.3, 0.4])
    map.strength = 0.0
    frame = TestImages.linear_image(32, 32) { |x, _| [0.3 * 1.4, 0.3, 0.3 * 0.4] }
    assert_operator (map.apply(frame) - frame).abs.max, :<, 1e-6
  end

  def test_it_moves_colour_toward_the_reference
    map = Emulsion::ChromaMap.new([0.6, 0.6], [0.0, 0.4])
    frame = TestImages.linear_image(32, 32) { |_x, _y| [0.3 * 1.4, 0.3, 0.3 * 2**-2.0] }
    before = TestImages.stops(TestImages.mean_pixel(frame, 4, 4, 24, 24))
    after = TestImages.stops(TestImages.mean_pixel(map.apply(frame), 4, 4, 24, 24))
    assert_operator after[1], :>, before[1], "blue should come up"
    assert_operator after[1], :<, 0.0, "but not past neutral"
  end

  # Reshaping colour that was never recorded only makes a louder wrong answer.
  def test_it_steps_aside_where_blue_is_gone
    map = Emulsion::ChromaMap.new([0.6, 0.6], [0.0, 0.4])
    frame = TestImages.linear_image(32, 32) { |_x, _y| [0.3 * 1.4, 0.3, 0.3 * 2**-4.0] }
    lost = weight(1.0)
    assert_operator (map.apply(frame, lost) - frame).abs.max, :<, 2e-3
    half = weight(0.5)
    moved = TestImages.stops(TestImages.mean_pixel(map.apply(frame, half), 4, 4, 24, 24))
    full = TestImages.stops(TestImages.mean_pixel(map.apply(frame), 4, 4, 24, 24))
    assert_operator moved[1], :<, full[1], "half lost should move half as far"
  end
end
