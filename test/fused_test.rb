require_relative "test_helper"

# --engine apple against libvips: every operation Fused runs on the GPU, the
# formats libvips would give, the images it hands back and forth, and a whole
# frame. Skipped where `rake apple_engine` has not been run.
class FusedTest < Minitest::Test
  F = FilmScan::Fused

  def setup
    skip FilmScan::Metal.unavailable_reason unless FilmScan::Metal.available?
    F.teach_vips
    @a = noise(0.5, 0.4).bandjoin([noise(0.3, 0.3), noise(0.0, 1.0)]).copy(interpretation: :srgb).copy_memory
    @b = noise(0.2, 0.5).copy_memory
  end

  def noise(mean, sigma)
    Vips::Image.gaussnoise(96, 64, mean: mean, sigma: sigma, seed: (mean * 100).to_i).cast(:float)
  end

  # Within float rounding: libvips works some steps in double.
  def assert_close(want, got, label, tolerance = 2e-6)
    want = want.cast(:float)
    got = got.vips.cast(:float)
    assert_equal want.bands, got.bands, label
    gap = ((want - got).abs / (want.abs + 1.0))
    gap = (gap == gap).ifthenelse(gap, 0)
    assert_operator gap.max, :<=, tolerance, label
  end

  LUT = Vips::Image.new_from_array([(0...256).map { |i| Math.sin(i / 40.0) }])

  OPERATIONS = {
    "add" => ->(x, y) { x + y }, "subtract a constant per band" => ->(x, _) { x - [0.1, 0.2, 0.3] },
    "multiply" => ->(x, y) { x * y }, "divide" => ->(x, y) { x / y }, "divide by a constant" => ->(x, _) { x / 12.92 },
    "power" => ->(x, _) { x**2.4 }, "negative integer power" => ->(x, _) { x**-1 }, "power of an image" => ->(x, y) { x.abs**y },
    "compare" => ->(x, y) { x > y }, "choose" => ->(x, _) { (x <= 0.04045).ifthenelse(x / 12.92, ((x + 0.055) / 1.055)**2.4) },
    "choose between constants" => ->(x, _) { (x > 0.5).ifthenelse(1.0, 0.0) },
    "choose a constant or an image" => ->(x, _) { (x < 1e-5).ifthenelse(1e-5, x) },
    "and" => ->(x, y) { (x > 0.1) & (y < 0.5) }, "log" => ->(x, _) { x.log }, "exp" => ->(x, _) { x.exp },
    "tanh" => ->(x, _) { x.tanh }, "atan" => ->(x, _) { x.atan }, "sin" => ->(x, _) { (x * 90).sin },
    "luma" => ->(x, _) { (x * [0.2126, 0.7152, 0.0722]).bandmean * 3.0 }, "a band" => ->(x, _) { x[1] },
    "bandjoin" => ->(x, y) { x[2].bandjoin([y, x[0]]) }, "bandjoin a constant" => ->(x, _) { x[0].bandjoin(0.5) },
    "cast to uchar" => ->(x, _) { (x * 255.0).cast(:uchar) }, "floor and rint" => ->(x, _) { (x * 10).floor + (x * 10).rint },
    "table" => ->(x, _) { (x.abs * 255).cast(:uchar).maplut(LUT) }, "linear" => ->(x, _) { x.linear([1, 2, 3], [0.5, 0, -1]) },
    "negate" => ->(x, _) { -x }, "one band against three" => ->(x, y) { x * y },
    "gaussian blur" => ->(x, _) { x.gaussblur(2.0) }, "wide blur" => ->(x, _) { x[1].gaussblur(12.0, min_ampl: 0.02) },
    "gradient across" => ->(x, _) { x[0].conv(FilmScan::Detail::DX, precision: :float) },
    "gradient down" => ->(x, _) { x[0].conv(FilmScan::Detail::DY, precision: :float) },
    "a blur in a chain" => ->(x, _) { (x - x.gaussblur(1.5)) * 2 }
  }.freeze

  def test_each_operation_gives_what_libvips_gives
    OPERATIONS.each do |label, step|
      got = step.(F.leaf(@a), F.leaf(@b))
      assert_kind_of F, got, label
      assert_close step.(@a, @b), got, label
    end
  end

  def test_formats_are_the_ones_libvips_gives
    x = F.leaf(@a)
    assert_equal :uchar, (x > 0.5).format
    assert_equal :uchar, (x > 0.5).vips.format
    # A constant against a mask takes the mask's format, so a fraction is lost.
    assert_equal [0], ((x > 0.5).ifthenelse(0.7, 0.2).vips.to_a.flatten.uniq)
    edges = Vips::Image.new_from_array([[0.5, 2.7, -0.3, 255.6, 300.0, -1.7]]).cast(:float)
    assert_equal edges.cast(:uchar).to_a, F.leaf(edges).cast(:uchar).vips.to_a
    table = Vips::Image.new_from_array([[10.0, 20.0, 30.0]])
    index = Vips::Image.new_from_array([[0, 1, 2, 3, 200]]).cast(:uchar)
    assert_equal index.maplut(table).to_a, F.leaf(index).maplut(table).vips.cast(:double).to_a
  end

  def test_libvips_images_take_fused_ones
    x = F.leaf(@a)
    assert_kind_of F, @b * x
    assert_close @b * @a, @b * x, "a vips image times a fused one"
    assert_close (@b > 0.2).ifthenelse(@a, 0), (@b > 0.2).ifthenelse(x, 0), "a vips mask choosing fused pixels"
    assert_close Vips::Image.bandjoin([@b, @a[0]]), F.leaf(Vips::Image.bandjoin([@b, x[0]])), "a join through libvips"
  end

  def test_what_it_cannot_fuse_goes_to_libvips
    x = F.leaf(@a) * 2
    assert_close (@a * 2).resize(0.5), x.resize(0.5), "a resize"
    assert_in_delta (@a * 2).avg, x.avg, 1e-6
    assert_close (@a * 2).extract_area(3, 4, 20, 10), x.extract_area(3, 4, 20, 10), "an area"
  end

  # Its numbers are data, so the same chain with new ones compiles nothing new.
  def test_a_chain_compiles_once_whatever_its_numbers
    (F.leaf(@a) * 0.5 + 0.1).vips
    before = FilmScan::Metal.kernels
    (F.leaf(@a) * 0.7 + 0.3).vips
    assert_equal before, FilmScan::Metal.kernels
  end

  def test_a_frame_comes_out_the_same_on_either_engine
    shade = ->(x, y) { FilmScan::Colour.srgb_to_linear_scalar((30 + 160.0 * x / 240 + 30.0 * y / 160) / 255.0) }
    scan = TestImages.linear_image(240, 160) { |x, y| [shade.(x, y) * 1.1, shade.(x, y), shade.(x, y) * 0.8] }
    options = FilmScan::DEFAULTS.merge(FilmScan::Profile.load("lucky-shd-400").settings)
                                .merge(fix: FilmScan::DEFAULT_FIXES)
    vips = FilmScan::Pipeline.new(options).render(scan)
    apple = FilmScan::Pipeline.new(options.merge(engine: "apple")).render(scan)

    assert_kind_of Vips::Image, apple
    steps = ((vips - apple).abs * 1023).max
    assert_operator steps, :<, 1.0
  end
end
