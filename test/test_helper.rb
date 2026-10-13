require "minitest/autorun"
require "tmpdir"
require_relative "../lib/film_scan"
require_relative "../lib/film_scan/cli"

# The shared roll fits go to a folder of the test run's own, not the user's.
ENV["XDG_CACHE_HOME"] = Dir.mktmpdir("film_scan_cache")
Minitest.after_run { FileUtils.remove_entry(ENV["XDG_CACHE_HOME"]) }

module TestImages
  module_function

  # A float sRGB image built from a block returning linear [r, g, b] per pixel.
  def linear_image(width, height)
    values = []
    height.times do |y|
      width.times { |x| values.concat(yield(x, y)) }
    end
    linear = Vips::Image.new_from_memory(values.pack("f*"), width, height, 3, :float)
    # Copied into libvips' own memory before it is handed out. An image built
    # over a Ruby string lost its hold on that string somewhere down a chain of
    # operations, and when the collector freed it the pipeline read garbage:
    # an average came back NaN in about half the runs of one pair of tests.
    FilmScan::Colour.to_srgb(linear).copy(interpretation: :srgb).copy_memory
  end

  # Stops of red and blue against green for one linear pixel.
  def stops(px)
    [Math.log2(px[0] / px[1]), Math.log2(px[2] / px[1])]
  end

  def mean_pixel(image, left, top, width, height)
    area = FilmScan::Colour.to_linear(image.extract_area(left, top, width, height))
    (0..2).map { |c| area[c].avg }
  end
end
