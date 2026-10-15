require_relative "test_helper"

# A film's own look, carried in its profile and taken by every roll that no
# --match gives one of its own.
class ProfileLookTest < Minitest::Test
  LIGHTER = {
    lightness: [[0.0, 5.0], [50.0, 58.0], [100.0, 100.0]],
    offsets: Array.new(FilmScan::LookMatch::BANDS.size) { [0.0, 0.0] },
    spread: 1.0
  }.freeze

  def profile_with(look)
    data = YAML.safe_load(File.read(File.join(FilmScan::Profile::DIR, "lucky-shd-400.yml")),
                          permitted_classes: [], aliases: false, symbolize_names: true)
    FilmScan::Profile.new("lucky-shd-400", data.merge(look: look, look_strength: 0.7))
  end

  def test_a_profile_carries_a_look
    profile = profile_with(LIGHTER)
    assert_equal 0.7, profile.settings[:look_strength]
    assert FilmScan::LookMatch.valid?(profile.settings[:look])
  end

  def test_a_look_of_the_wrong_shape_is_refused
    error = assert_raises(ArgumentError) { profile_with(LIGHTER.merge(offsets: [[0.0, 0.0]])) }
    assert_match(/measure_look/, error.message)
  end

  def test_a_roll_takes_the_films_look_at_its_strength
    fits = quietly { FilmScan::CLI.new.send(:film_look, {}, look: LIGHTER, look_strength: 0.7) }
    assert_kind_of FilmScan::LookMatch, fits[:look]
    assert_in_delta 0.7, fits[:look].strength, 1e-9
  end

  def test_a_matched_roll_keeps_its_own_look
    own = FilmScan::LookMatch.new(lightness: [[0.0, 0.0], [100.0, 100.0]], offsets: LIGHTER[:offsets], spread: 1.0)
    fits = quietly { FilmScan::CLI.new.send(:film_look, { look: own }, look: LIGHTER, look_strength: 0.7) }
    assert_same own, fits[:look]
  end

  def test_no_look_at_no_strength_or_in_black_and_white
    cli = FilmScan::CLI.new
    assert_nil cli.send(:film_look, {}, look: LIGHTER, look_strength: 0.0)[:look]
    assert_nil cli.send(:film_look, {}, look: LIGHTER, look_strength: 1.0, monochrome: true)[:look]
  end

  def test_the_look_lightens_a_frame
    frame = TestImages.linear_image(60, 40) { |x, _| [0.05 + x / 300.0] * 3 }
    look = FilmScan::LookMatch.from_cache(LIGHTER)
    lab = ->(image) { FilmScan::LookMatch.lab_of(image)[0].avg }
    assert_operator lab.(look.apply(frame)), :>, lab.(frame) + 4
  end

  def quietly
    out = $stdout
    $stdout = File.open(File::NULL, "w")
    yield
  ensure
    $stdout = out
  end
end
