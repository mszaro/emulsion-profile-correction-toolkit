require_relative "test_helper"

class ProfilesTest < Minitest::Test
  def test_every_profile_loads
    FilmScan::Profile.available.each do |name|
      profile = FilmScan::Profile.load(name)
      FilmScan::Reference.load(profile.settings[:reference]) if profile.settings[:reference]
    end
  end

  def test_every_film_balances_toward_superia
    %w[harman-phoenix-200 lucky-shd-400 lomochrome-color-92].each do |name|
      settings = FilmScan::Profile.load(name).settings
      assert_equal "fujifilm-superia", settings[:reference], name
      assert_equal FilmScan::ColourBalance::TONES.size, settings[:film_gains]&.size, "#{name} film gains"
    end
  end

  def test_superia_reference_has_a_neutral_and_a_shape
    reference = FilmScan::Reference.load("fujifilm-superia")
    assert_equal FilmScan::ColourBalance::TONES.size, reference.neutral.size
    assert_equal FilmScan::ToneCurve::QUANTILES.size, reference.tone_shape.size
  end

  def test_reference_measured_on_other_bands_is_refused
    Dir.mktmpdir do |dir|
      path = File.join(dir, "old.yml")
      File.write(path, "tones: [0.1, 0.5]\nneutral: [[0, 0], [0, 0]]\n")
      error = assert_raises(ArgumentError) { FilmScan::Reference.load(path) }
      assert_match(/other tone bands/, error.message)
    end
  end

  def test_unknown_reference_names_the_ones_available
    error = assert_raises(ArgumentError) { FilmScan::Reference.load("kodak-imaginary") }
    assert_match(/fujifilm-superia/, error.message)
  end
end
