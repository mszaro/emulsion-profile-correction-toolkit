require_relative "test_helper"

class OrientationCheckTest < Minitest::Test
  Check = FilmScan::OrientationCheck

  # Stands in for the network: whichever edge is brightest is the top.
  BRIGHT_TOP = lambda do |image|
    w = image.width
    h = image.height
    band = [w, h].min / 6
    edges = { 0 => image.extract_area(0, 0, w, band), 90 => image.extract_area(w - band, 0, band, h),
              180 => image.extract_area(0, h - band, w, band), 270 => image.extract_area(0, 0, band, h) }
    turn = edges.max_by { _2.avg }[0]
    Check::TURNS.map { _1 == turn ? 1.0 : 0.0 }
  end

  def teardown
    FilmScan::Orientation.overrides = {}
  end

  # A landscape scan whose top, as the stand-in reads it, is the `bright` edge.
  def scan(dir, stem, bright:, tag: nil)
    image = TestImages.linear_image(192, 128) do |x, y|
      along = { top: 1 - y / 127.0, bottom: y / 127.0, left: 1 - x / 191.0, right: x / 191.0 }.fetch(bright)
      [0.02 + 0.8 * along] * 3
    end
    image = (image * 255).cast(:uchar).copy
    image.set_type(GObject::GINT_TYPE, "orientation", tag) if tag
    path = File.join(dir, "#{stem}.tif")
    image.write_to_file(path)
    path
  end

  # Three portraits the lab tagged 8, so the roll's portraits go 8, and a
  # landscape frame the right way up.
  def roll(dir)
    (1..3).map { |n| scan(dir, format("%06d", n), bright: :right, tag: 8) } + [scan(dir, "000004", bright: :top)]
  end

  def check(paths, roll: paths, predict: BRIGHT_TOP)
    Check.new(predict, log: StringIO.new).check(paths, roll: roll)
  end

  def test_an_untagged_portrait_turned_the_rolls_way_is_sure
    Dir.mktmpdir do |dir|
      frames = roll(dir) + [scan(dir, "000005", bright: :right)]
      findings = check(frames)
      assert_equal ["000005"], findings.map(&:stem)
      assert_equal 8, findings.first.suggested
      assert findings.first.sure
    end
  end

  def test_an_untagged_portrait_turned_against_the_rolls_way_needs_a_look
    Dir.mktmpdir do |dir|
      found = check(roll(dir) + [scan(dir, "000005", bright: :left)]).first
      assert_equal 6, found.suggested
      refute found.sure
      assert_match(/portraits go 8/, found.why)
    end
  end

  # The lab's tag was right far more often than the network on this
  # collection, so turning against a tag always needs a look.
  def test_a_frame_against_its_tag_needs_a_look
    Dir.mktmpdir do |dir|
      found = check(roll(dir) + [scan(dir, "000005", bright: :left, tag: 8)]).first
      assert_equal 6, found.suggested, "upside down as tagged, so the other quarter turn"
      refute found.sure
      assert_match(/lab tagged it 8/, found.why)
    end
  end

  def test_a_frame_with_an_override_is_judged_as_the_override_writes_it
    Dir.mktmpdir do |dir|
      frames = roll(dir) + [scan(dir, "000005", bright: :right)]
      FilmScan::Orientation.overrides = { frames.last => 8 }
      assert_empty check(frames), "the override already stands it up"
      FilmScan::Orientation.overrides = { frames.last => 3 }
      found = check(frames).first
      assert_equal 8, found.suggested
      refute found.sure
      assert_match(/already has an override of 3/, found.why)
    end
  end

  def test_a_roll_with_too_few_portraits_has_no_way_to_go
    Dir.mktmpdir do |dir|
      frames = [scan(dir, "000001", bright: :top), scan(dir, "000002", bright: :right)]
      found = check(frames).first
      refute found.sure
      assert_match(/too few portraits/, found.why)
    end
  end

  # A network that says a frame was turned the same way however it is shown
  # is not reading the picture, and flags nothing.
  def test_calls_that_do_not_follow_the_turns_flag_nothing
    Dir.mktmpdir do |dir|
      stubborn = ->(_image) { Check::TURNS.map { _1 == 90 ? 1.0 : 0.0 } }
      assert_empty check(roll(dir), predict: stubborn)
    end
  end

  def test_the_report_gives_sure_frames_to_paste_and_the_rest_commented_out
    Dir.mktmpdir do |dir|
      frames = roll(dir) + [scan(dir, "000005", bright: :right), scan(dir, "000006", bright: :left)]
      report = Check.new(BRIGHT_TOP, log: StringIO.new).report(check(frames), frames.size)
      pasted = YAML.safe_load(report)
      assert_equal({ "000005" => { "orientation" => 8 } }, pasted)
      assert_match(/^# "000006": \{ orientation: 6 \}/, report)
      assert_equal "all 4 frames look the right way up", Check.new(BRIGHT_TOP).report([], 4)
    end
  end

  # The command says what it found and writes no frames, only the sheet of
  # the frames to look at when one is asked for.
  def test_orient_suggests_and_changes_nothing
    Dir.mktmpdir do |dir|
      source = File.join(dir, "roll")
      Dir.mkdir(source)
      roll(source)
      scan(source, "000005", bright: :right)
      out_dir = File.join(dir, "out")
      cli = FilmScan::CLI.new
      cli.define_singleton_method(:orientation_check) { Check.new(BRIGHT_TOP, log: StringIO.new) }
      status = nil
      out, = capture_io { status = cli.run(["--orient", "--contact-sheet", "--out", out_dir, source]) }
      assert_equal 0, status, out
      assert_match(/^"000005": \{ orientation: 8 \}/, out)
      assert_equal ["orientation.jpg"], Dir.children(out_dir)
      assert_empty FilmScan::Orientation.overrides
    end
  end

  # The real network on a real frame, when a copy of it is at hand: the
  # portrait from the examples, upright, stored sideways and tagged, and
  # stored sideways with no tag.
  def test_the_network_reads_a_real_frame
    before = ENV["FILM_SCAN_ORIENTATION_MODEL"]
    model = ENV["FILM_SCAN_ORIENTATION_MODEL"] || File.join(Dir.home, ".cache", "film_scan", "models", Check::MODEL_NAME)
    skip "no copy of the orientation model" unless File.exist?(model)
    skip "the onnxruntime gem is not installed" unless Gem::Specification.find_all_by_name("onnxruntime").any?

    ENV["FILM_SCAN_ORIENTATION_MODEL"] = model
    Dir.mktmpdir do |dir|
      upright = Vips::Image.new_from_file(File.expand_path("../examples/000051-before-after.jpg", __dir__))
                           .extract_area(525, 0, 497, 748)
      frames = (1..3).map do |n|
        stored = upright.rot(:d90).copy
        stored.set_type(GObject::GINT_TYPE, "orientation", 8)
        path = File.join(dir, format("%06d.tif", n))
        stored.write_to_file(path)
        path
      end
      sideways = File.join(dir, "000004.tif")
      upright.rot(:d90).write_to_file(sideways)
      findings = Check.new(log: StringIO.new).check(frames + [sideways])
      assert_equal ["000004"], findings.map(&:stem)
      assert_equal 8, findings.first.suggested
      assert findings.first.sure
    end
  ensure
    ENV["FILM_SCAN_ORIENTATION_MODEL"] = before
  end
end
