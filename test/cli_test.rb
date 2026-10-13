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
    out, = capture_io { status = FilmScan::CLI.run(args) }
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

  # A roll rendered again into another folder reuses what was measured for
  # the first one, and the new folder gets the same fits beside it.
  def test_a_second_folder_reuses_the_roll_analysis
    Dir.mktmpdir do |dir|
      source = File.join(dir, "roll")
      Dir.mkdir(source)
      write_roll(source, frames: 2)
      first = File.join(dir, "first")
      second = File.join(dir, "second")

      status, out = run_cli("--profile", "lucky-shd-400", "--out", first, source)
      assert_equal 0, status, out
      status, out = run_cli("--profile", "lucky-shd-400", "--out", second, source)
      assert_equal 0, status, out
      assert_match(/reusing the roll analysis/, out)
      assert_equal File.read(File.join(first, "roll-fit.yml")), File.read(File.join(second, "roll-fit.yml"))

      # A setting the tuning renders read is part of the key.
      status, out = run_cli("--profile", "lucky-shd-400", "--contrast", "0.2", "--out", File.join(dir, "third"), source)
      assert_equal 0, status, out
      refute_match(/reusing the roll analysis/, out)
    end
  end

  # Film the lab scanned well only changes container: every pixel comes back
  # as it went in, and no profile is needed.
  def test_convert_only_leaves_the_pixels_alone
    Dir.mktmpdir do |dir|
      source = File.join(dir, "roll")
      Dir.mkdir(source)
      write_roll(source, frames: 2)
      out_dir = File.join(dir, "out")
      status, out = run_cli("--convert-only", "--format", "png", "--bits", "8", "--out", out_dir, source)
      assert_equal 0, status, out
      Dir.glob(File.join(source, "*.png")).each do |original|
        converted = File.join(out_dir, File.basename(original))
        diff = (Vips::Image.new_from_file(original).cast(:int) - Vips::Image.new_from_file(converted).cast(:int)).abs.max
        assert_equal 0, diff, File.basename(original)
      end
    end
  end

  # heif-enc runs beside the next frame, and the run still ends with every
  # frame finished, in order, and nothing temporary left behind.
  def test_a_heic_roll_finishes_every_frame
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    Dir.mktmpdir do |dir|
      source = File.join(dir, "roll")
      Dir.mkdir(source)
      write_roll(source, frames: 3)
      out_dir = File.join(dir, "out")
      status, out = run_cli("--convert-only", "--format", "heic", "--out", out_dir, source)
      assert_equal 0, status, out
      assert_equal %w[000001.heic 000002.heic 000003.heic], Dir.children(out_dir).grep(/heic/).sort
      assert_empty Dir.children(out_dir).grep(/partial|\.png/)
      assert_equal %w[1 2 3], out.scan(%r{\[(\d)/3\]}).flatten
    end
  end

  # A bare --fix just before the folder takes the usual set, not the folder.
  def test_a_bare_fix_does_not_take_the_folder
    assert_equal ["--fix=#{FilmScan::DEFAULT_FIXES.join(",")}", "/scans/roll"], FilmScan::CLI.bare_fix(["--fix", "/scans/roll"])
    assert_equal ["--fix", "floor,shadows", "/scans/roll"], FilmScan::CLI.bare_fix(["--fix", "floor,shadows", "/scans/roll"])
    assert_equal ["--fix", "all", "/x"], FilmScan::CLI.bare_fix(["--fix", "all", "/x"])
    assert_equal ["--fix=#{FilmScan::DEFAULT_FIXES.join(",")}"], FilmScan::CLI.bare_fix(["--fix"])
  end

  def test_unknown_reference_fails_cleanly
    Dir.mktmpdir do |dir|
      write_roll(dir, frames: 1)
      status = nil
      _, err = capture_io do
        status = FilmScan::CLI.run(["--profile", "lucky-shd-400", "--reference", "nope",
                                    "--out", File.join(dir, "out"), dir])
      end
      assert_equal 1, status
      assert_match(/no reference called nope/, err)
    end
  end
end
