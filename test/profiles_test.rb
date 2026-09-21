require_relative "test_helper"

class ProfilesTest < Minitest::Test
  def test_every_profile_loads
    Emulsion::Profile.available.each do |name|
      profile = Emulsion::Profile.load(name)
      Emulsion::Reference.load(profile.settings[:reference]) if profile.settings[:reference]
    end
  end

  def test_every_film_balances_toward_superia
    %w[harman-phoenix-200 lucky-shd-400 lomochrome-color-92].each do |name|
      settings = Emulsion::Profile.load(name).settings
      assert_equal "fujifilm-superia", settings[:reference], name
      assert_equal Emulsion::ColourBalance::TONES.size, settings[:film_gains]&.size, "#{name} film gains"
    end
  end

  def test_superia_reference_has_a_neutral_and_a_shape
    reference = Emulsion::Reference.load("fujifilm-superia")
    assert_equal Emulsion::ColourBalance::TONES.size, reference.neutral.size
    assert_equal Emulsion::ToneCurve::QUANTILES.size, reference.tone_shape.size
  end

  def test_reference_measured_on_other_bands_is_refused
    Dir.mktmpdir do |dir|
      path = File.join(dir, "old.yml")
      File.write(path, "tones: [0.1, 0.5]\nneutral: [[0, 0], [0, 0]]\n")
      error = assert_raises(ArgumentError) { Emulsion::Reference.load(path) }
      assert_match(/other tone bands/, error.message)
    end
  end

  def test_unknown_reference_names_the_ones_available
    error = assert_raises(ArgumentError) { Emulsion::Reference.load("kodak-imaginary") }
    assert_match(/fujifilm-superia/, error.message)
  end
end
