require_relative "test_helper"

class ContactSheetTest < Minitest::Test
  def frame(shade)
    TestImages.linear_image(90, 60) { |_x, _y| [shade, shade, shade] }
  end

  def test_a_sheet_holds_a_tile_per_frame
    sheet = Emulsion::ContactSheet.new("49602 Lucky SHD 400")
    assert sheet.empty?
    3.times { |n| sheet.add(frame(0.2 + n * 0.2), format("%06d", n + 1)) }
    refute sheet.empty?
    Dir.mktmpdir do |dir|
      path = sheet.write(File.join(dir, "contact.jpg"))
      image = Vips::Image.new_from_file(path)
      # A sheet is always six across, however few frames the roll holds.
      assert_equal 6 * Emulsion::ContactSheet::TILE + 5 * Emulsion::ContactSheet::GAP, image.width
      assert_operator image.height, :>, Emulsion::ContactSheet::TILE, "the title sits above the frames"
    end
  end

  def test_a_sheet_with_no_frames_writes_nothing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "contact.jpg")
      assert_nil Emulsion::ContactSheet.new("empty roll").write(path)
      refute File.exist?(path)
    end
  end

  # Six across, so a seventh frame starts a second row.
  def test_the_sheet_wraps_at_six_frames
    sheet = Emulsion::ContactSheet.new("a roll")
    7.times { |n| sheet.add(frame(0.3), format("%06d", n)) }
    Dir.mktmpdir do |dir|
      image = Vips::Image.new_from_file(sheet.write(File.join(dir, "contact.jpg")))
      assert_equal 6 * Emulsion::ContactSheet::TILE + 5 * Emulsion::ContactSheet::GAP, image.width
    end
  end
end
