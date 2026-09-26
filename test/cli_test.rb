require_relative "test_helper"

class CLITest < Minitest::Test
  # A few small frames with a Lucky-like cast: blue short in the midtones.
  def write_roll(dir, frames: 4)
    frames.times do |n|
      image = TestImages.linear_image(96, 64) do |x, y|
        luma = Math.exp(Math.log(0.004) + (x + n) / 100.0 * (Math.log(0.8) - Math.log(0.004)))
        tint = y < 20 ? [0.6, 1.0, 1.6] : [1.0, 1.0, 1.0]
        [luma * tint[0], luma * tint[1], 0.5 * (luma * tint[2])**1.3]
      end
      (image * 255).cast(:uchar).pngsave(File.join(dir, format("%06d.png", n + 1)))
    end
  end

  def run_cli(*args)
    status = nil
    out, = capture_io { status = Emulsion::CLI.run(args) }
    [status, out]
  end

  def test_lucky_profile_corrects_a_roll_and_caches_its_fits
    Dir.mktmpdir do |dir|
      source = File.join(dir, "roll")
      Dir.mkdir(source)
      write_roll(source)
      out_dir = File.join(dir, "out")

      status, out = run_cli("--profile", "lucky-shd-400", "--out", out_dir, source)
      assert_equal 0, status, out
      assert_match(/balancing the roll toward FujiFilm Superia/, out)
      assert_equal 4, Dir.glob(File.join(out_dir, "*.png")).size

      cache = YAML.safe_load(File.read(File.join(out_dir, "roll-fit.yml")))
      assert cache["balance"], "the roll balance should be cached"
      assert cache["tone"], "the tone curve should be cached"

      status, out = run_cli("--profile", "lucky-shd-400", "--out", out_dir, source)
      assert_equal 0, status
      assert_match(/reusing the roll analysis/, out)
    end
  end

  def test_unknown_reference_fails_cleanly
    Dir.mktmpdir do |dir|
      write_roll(dir, frames: 1)
      status = nil
      _, err = capture_io do
        status = Emulsion::CLI.run(["--profile", "lucky-shd-400", "--reference", "nope",
                                    "--out", File.join(dir, "out"), dir])
      end
      assert_equal 1, status
      assert_match(/no reference called nope/, err)
    end
  end
end
