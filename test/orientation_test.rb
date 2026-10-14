require_relative "test_helper"

class OrientationTest < Minitest::Test
  def teardown
    FilmScan::Orientation.overrides = {}
  end

  # A landscape frame that brightens from left to right, so which way it was
  # turned shows in where the bright edge ends up.
  def scan(path, tag: nil)
    image = TestImages.linear_image(384, 256) { |x, _| [0.02 + 0.8 * x / 383.0] * 3 }
    image = (image * 255).cast(:uchar)
    if tag
      image = image.copy
      image.set_type(GObject::GINT_TYPE, "orientation", tag)
    end
    image.write_to_file(path)
  end

  def roll(dir, tags: [nil, nil])
    source = File.join(dir, "roll")
    Dir.mkdir(source)
    tags.each_with_index { |tag, i| scan(File.join(source, format("%06d.tif", i + 1)), tag: tag) }
    source
  end

  # An overrides file giving the first frame these settings.
  def overrides(dir, **settings)
    path = File.join(dir, "overrides.yml")
    File.write(path, YAML.dump("000001" => settings.transform_keys(&:to_s)))
    path
  end

  def run_cli(*args)
    status = nil
    out, = capture_io { status = FilmScan::CLI.run(args) }
    [status, out]
  end

  def edges(image)
    rows = [image.height / 8, 1].max
    [image.extract_area(0, 0, image.width, rows).avg, image.extract_area(0, image.height - rows, image.width, rows).avg]
  end

  # The lab left a portrait frame untagged; its override turns it a quarter
  # anticlockwise, so its bright right edge ends up at the top.
  def test_an_override_stands_a_frame_upright_in_the_written_file
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    Dir.mktmpdir do |dir|
      out_dir = File.join(dir, "out")
      status, out = run_cli("--convert-only", "--format", "heic", "--overrides", overrides(dir, orientation: 8),
                            "--out", out_dir, roll(dir))
      assert_equal 0, status, out
      turned = Vips::Image.new_from_file(File.join(out_dir, "000001.heic"))
      assert_equal [256, 384], [turned.width, turned.height]
      top, bottom = edges(turned)
      assert_operator top, :>, bottom * 2, "the right edge should be at the top"
      left_alone = Vips::Image.new_from_file(File.join(out_dir, "000002.heic"))
      assert_equal [384, 256], [left_alone.width, left_alone.height]
      assert_empty FilmScan::Orientation.overrides, "the run should leave no overrides behind"
    end
  end

  # A format that keeps the tag rather than turning the pixels gets the
  # override as its tag.
  def test_a_tiff_carries_the_override_as_its_tag
    Dir.mktmpdir do |dir|
      out_dir = File.join(dir, "out")
      status, out = run_cli("--convert-only", "--format", "tiff", "--overrides", overrides(dir, orientation: 8),
                            "--out", out_dir, roll(dir))
      assert_equal 0, status, out
      assert_equal 8, FilmScan::Orientation.tag(File.join(out_dir, "000001.tiff"))
      assert_equal 1, FilmScan::Orientation.tag(File.join(out_dir, "000002.tiff"))
    end
  end

  # The contact sheet shows the frame the way it is written, which is where a
  # frame still the wrong way up gets spotted.
  def test_the_contact_sheet_shows_the_frame_as_written
    Dir.mktmpdir do |dir|
      out_dir = File.join(dir, "out")
      status, out = run_cli("--convert-only", "--format", "jpeg", "--contact-sheet", "--only", "000001",
                            "--overrides", overrides(dir, orientation: 8), "--out", out_dir, roll(dir))
      assert_equal 0, status, out
      sheet = Vips::Image.new_from_file(File.join(out_dir, "contact.jpg"))
      tile = FilmScan::ContactSheet::TILE
      picture = sheet.extract_area(0, sheet.height - tile, tile, tile - FilmScan::ContactSheet::CAPTION)
      _, _, width, height = picture.find_trim(threshold: 20, background: FilmScan::ContactSheet::BACKGROUND)
      assert_operator height, :>, width * 1.3, "the tile should be portrait"
    end
  end

  # A landscape frame the lab tagged as portrait comes back as scanned with an
  # override of 1, and the frame beside it still follows its tag.
  def test_an_override_of_one_leaves_a_tagged_frame_as_scanned
    skip "heif-enc is not installed" unless FilmScan::CLI::HEIF_ENC
    Dir.mktmpdir do |dir|
      out_dir = File.join(dir, "out")
      status, out = run_cli("--convert-only", "--format", "heic", "--overrides", overrides(dir, orientation: 1),
                            "--out", out_dir, roll(dir, tags: [6, 6]))
      assert_equal 0, status, out
      kept = Vips::Image.new_from_file(File.join(out_dir, "000001.heic"))
      assert_equal [384, 256], [kept.width, kept.height]
      tagged = Vips::Image.new_from_file(File.join(out_dir, "000002.heic"))
      assert_equal [256, 384], [tagged.width, tagged.height]
    end
  end

  # The frames the roll is analysed from are shrunk and turned by an override
  # exactly as by the tag it stands in for.
  def test_an_override_turns_a_thumbnail_as_its_tag_would
    Dir.mktmpdir do |dir|
      plain = File.join(dir, "plain.tif")
      scan(plain)
      [3, 6, 8].each do |turn|
        tagged = File.join(dir, "tagged-#{turn}.tif")
        scan(tagged, tag: turn)
        FilmScan::Orientation.overrides = { plain => turn }
        expected = Vips::Image.thumbnail(tagged, 48, size: :down)
        got = FilmScan::Orientation.thumbnail(plain, 48)
        assert_equal [expected.width, expected.height], [got.width, got.height], "orientation #{turn}"
        assert_equal 0, (expected.cast(:int) - got.cast(:int)).abs.max, "orientation #{turn}"
      end
    end
  end

  # Upside down, the sky sits at the bottom and is not found. With the frame's
  # override it is, and the mask comes back matching the pixels as loaded.
  def test_an_override_reaches_the_sky_detector
    Dir.mktmpdir do |dir|
      sky = (0.45 * 150).to_i
      upright = TestImages.linear_image(200, 150) do |x, y|
        next [0.30, 0.34, 0.45] if y < sky

        busy = ((x / 3) + (y / 3)).even? ? 1.6 : 0.5
        [0.12 * busy, 0.12 * busy * 0.95, 0.12 * busy * 0.9]
      end
      path = File.join(dir, "000001.png")
      (upright.rot(:d180) * 255).cast(:uchar).pngsave(path)

      assert_nil FilmScan::Sky.mask(FilmScan::Colour.load(path))

      FilmScan::Orientation.overrides = { path => 3 }
      mask = FilmScan::Sky.mask(FilmScan::Colour.load(path))
      refute_nil mask
      assert_in_delta 1.0, mask.extract_area(10, 150 - sky + 10, 180, sky - 20).avg, 0.05, "the sky is at the bottom"
      assert_in_delta 0.0, mask.extract_area(10, 10, 180, 40).avg, 0.05, "the ground is at the top"
    end
  end

  # The roll's analysis reads frames the right way up, so a new override
  # means measuring the roll again.
  def test_an_override_is_part_of_the_roll_analysis_key
    Dir.mktmpdir do |dir|
      source = roll(dir)
      out_dir = File.join(dir, "out")
      status, out = run_cli("--profile", "lucky-shd-400", "--out", out_dir, source)
      assert_equal 0, status, out
      status, out = run_cli("--profile", "lucky-shd-400", "--overrides", overrides(dir, saturation: 1.2),
                            "--out", out_dir, source)
      assert_equal 0, status, out
      assert_match(/reusing the roll analysis/, out)
      status, out = run_cli("--profile", "lucky-shd-400", "--overrides", overrides(dir, orientation: 8),
                            "--out", out_dir, source)
      assert_equal 0, status, out
      refute_match(/reusing the roll analysis/, out)
    end
  end

  def test_a_mirrored_orientation_is_refused
    Dir.mktmpdir do |dir|
      error = assert_raises(RuntimeError) do
        run_cli("--convert-only", "--overrides", overrides(dir, orientation: 5),
                "--out", File.join(dir, "out"), roll(dir))
      end
      assert_match(/orientation for 000001 must be one of 1, 3, 6, 8/, error.message)
    end
  end
end
