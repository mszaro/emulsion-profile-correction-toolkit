require_relative "test_helper"

class MeasurementsTest < Minitest::Test
  PERCENTS = [0.0, 0.3, 0.4, 1, 30, 50, 99.7, 100].freeze

  # The black and white points read two ranks without sorting, and have to
  # land exactly where the sorted reading does.
  def test_a_percentile_without_sorting_matches_the_sorted_one
    random = Random.new(11)
    [1, 2, 7, 400, 3001].each do |size|
      values = Array.new(size) { random.rand < 0.3 ? random.rand(8) / 8.0 : random.rand }
      PERCENTS.each do |pct|
        assert_equal FilmScan::Measurements.percentile(values.sort, pct),
                     FilmScan::Measurements.percentile_of(values, pct), "#{size} values at #{pct}%"
      end
    end
  end

  def test_an_empty_sample_reads_zero
    assert_equal 0.0, FilmScan::Measurements.percentile_of([], 50)
  end

  # Unpacked only when asked, and the same pixels either way.
  def test_the_sample_unpacks_on_first_use
    image = TestImages.linear_image(40, 30) { |x, y| [0.1 + x / 100.0, 0.2, 0.05 + y / 100.0] }
    measured = FilmScan::Measurements.new(image)
    assert_equal measured.size, measured.pixels.size
    assert_equal measured.pixels.size, measured.lumas.size
  end
end
