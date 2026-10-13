require_relative "test_helper"

class MatchTest < Minitest::Test
  # A gradient from deep shadow to near white, so every tone band has greys.
  def write_frames(dir, tint, frames: 3)
    Dir.mkdir(dir)
    frames.times do |n|
      image = TestImages.linear_image(96, 64) do |x, _y|
        luma = Math.exp(Math.log(0.004) + (x + n) / 100.0 * (Math.log(0.8) - Math.log(0.004)))
        [luma * tint[0], luma * tint[1], luma * tint[2]]
      end
      (image * 255).cast(:uchar).pngsave(File.join(dir, format("%06d.png", n + 1)))
    end
  end

  def run_cli(*args)
    status = nil
    out, = capture_io { status = FilmScan::CLI.run(args) }
    [status, out]
  end

  # Mean blue against red over a roll's corrected frames, in stops.
  def coolness(dir)
    Dir.glob(File.join(dir, "*.png")).sum do |path|
      image = FilmScan::Colour.to_linear(Vips::Image.new_from_file(path).cast(:float) / 255.0)
      Math.log2(image[2].avg / image[0].avg)
    end
  end

  def test_measures_a_reference_from_rolls
    Dir.mktmpdir do |dir|
      write_frames(File.join(dir, "cool"), [0.85, 1.0, 1.18])
      paths = Dir.glob(File.join(dir, "cool", "*.png")).sort
      reference = FilmScan::Reference.measure({ "cool" => paths }, id: "cool", name: "Cool", verbose: false)

      assert_equal FilmScan::ColourBalance::TONES.size, reference.neutral.size
      red, blue = reference.neutral[5]
      assert_operator blue - red, :>, 0.3, "a cool roll should measure blue over red"
      assert_equal FilmScan::ToneCurve::QUANTILES.size, reference.tone_shape.size

      copy = FilmScan::Reference.new("copy", YAML.safe_load(reference.to_yaml("Test"), symbolize_names: true))
      copy.neutral.flatten.zip(reference.neutral.flatten).each { |read, measured| assert_in_delta measured, read, 0.0006 }
    end
  end

  # The same roll matched to a cool roll and to a warm one comes out cooler
  # against the first, and the measured reference is kept and reused.
  def test_a_roll_is_balanced_toward_the_rolls_it_matches
    Dir.mktmpdir do |dir|
      write_frames(File.join(dir, "cool"), [0.85, 1.0, 1.18])
      write_frames(File.join(dir, "warm"), [1.18, 1.0, 0.85])
      write_frames(File.join(dir, "roll"), [1.05, 1.0, 0.9], frames: 4)

      outs = %w[cool warm].to_h do |name|
        out_dir = File.join(dir, "out-#{name}")
        status, out = run_cli("--profile", "lucky-shd-400", "--match", File.join(dir, name),
                              "--format", "png", "--bits", "8", "--out", out_dir, File.join(dir, "roll"))
        assert_equal 0, status, out
        assert_match(/measuring #{name} \(3 frames\) to match/, out)
        assert File.exist?(File.join(out_dir, "match-reference.yml"))
        [name, out_dir]
      end
      assert_operator coolness(outs["cool"]) - coolness(outs["warm"]), :>, 0.2

      status, out = run_cli("--profile", "lucky-shd-400", "--match", File.join(dir, "cool"),
                            "--format", "png", "--bits", "8", "--out", outs["cool"], File.join(dir, "roll"))
      assert_equal 0, status, out
      assert_match(/as measured before/, out)
    end
  end

  # A pattern picks some of a roll's frames, such as only its city shots.
  def test_matches_some_of_a_rolls_frames
    Dir.mktmpdir do |dir|
      write_frames(File.join(dir, "cool"), [0.85, 1.0, 1.18])
      write_frames(File.join(dir, "roll"), [1.05, 1.0, 0.9], frames: 2)
      status, out = run_cli("--profile", "lucky-shd-400", "--match", File.join(dir, "cool", "00000[12].png"),
                            "--format", "png", "--bits", "8", "--out", File.join(dir, "out"), File.join(dir, "roll"))
      assert_equal 0, status, out
      assert_match(/measuring cool \(2 frames\) to match/, out)
    end
  end

  def test_a_missing_roll_to_match_fails_cleanly
    Dir.mktmpdir do |dir|
      write_frames(File.join(dir, "roll"), [1.0, 1.0, 1.0], frames: 1)
      status = nil
      _, err = capture_io do
        status = FilmScan::CLI.run(["--profile", "lucky-shd-400", "--match", File.join(dir, "nope"),
                                    "--out", File.join(dir, "out"), File.join(dir, "roll")])
      end
      assert_equal 1, status
      assert_match(/no frames to match/, err)
    end
  end
end
