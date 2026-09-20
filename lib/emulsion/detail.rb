module Emulsion
  # How sharp a frame really is under its grain, and the sharpening that earns
  # its place.
  #
  # Film grain is high-frequency energy spread over the whole frame, flat sky
  # included, so anything that counts fine detail alone reads a grainy scan as
  # a sharp one. The grain's own level is measured first, from the quietest
  # tiles, and every figure after that is edge energy above that floor. A frame
  # that moved or missed focus has no sharp edge anywhere, so it is left as it
  # is rather than sharpened into grain.
  module Detail
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Scanner borders would read as the hardest edge in the frame, so the
    # measurement stays inside a 5% inset as it does in Measurements.
    INSET = 0.05

    # Sizes are given in pixels of a 6144-wide scan and scaled to the frame in
    # hand, since grain and lens softness cover fewer pixels in a smaller copy.
    # A whole frame is expected rather than a crop, for the same reason.
    FULL_WIDTH = 6144.0

    # The blur the grain is measured against, and the finer of the two scales
    # the softness is read from. Nothing goes below MIN_SIGMA, where a blur
    # stops doing anything at all.
    GRAIN_SIGMA = 1.5
    FINE_SIGMA = 1.8
    COARSE_RATIO = 2.0
    MIN_SIGMA = 0.7

    # Roughly this many tiles whatever the frame's size, so one tile covers the
    # same piece of the scene in a thumbnail as in a full scan.
    TARGET_TILES = 3000
    MIN_TILE = 8

    # The quietest tiles are taken as grain alone, the busiest as whatever real
    # edges the frame has.
    QUIET_PCT = 10
    EDGE_PCT = 98

    # Tiles outside this are left out. Below it the scan sits on its floor, and
    # above it a scan made with the wrong profile has its tones squeezed toward
    # white, where grain reads far quieter than it is in the part of the frame
    # anyone looks at.
    DARK = 0.04
    BRIGHT = 0.85
    MIN_TILES = 40

    # How much edge energy a frame needs above its grain floor before it is
    # worth sharpening, as a multiple of that floor. Only a frame with no real
    # subject in it, or one soft from corner to corner, comes in under this.
    # The same test decides whether one axis has anything to say, since a frame
    # of horizontal strata is not blurred sideways, it is just striped.
    MIN_EDGE = 5.0

    # The softest edge still worth recovering, the radii to sharpen with, all
    # as multiples of the fine scale, and the softest reading worth making.
    # Past the first the frame moved or missed focus and sharpening would only
    # find grain.
    MAX_BLUR = 2.8
    MIN_RADIUS = 0.6
    MAX_RADIUS = 2.2
    BLUR_CEILING = 12.0

    # Strength at amount 1.0, and the grain level a frame gets half of it at,
    # since grain rides on every edge and is lifted along with it.
    GAIN = 1.4
    GRAIN_KNEE = 0.02

    # How far above the grain floor a neighbourhood has to be to count as an
    # edge, and how widely that is felt. Flat grain lands far below it and
    # takes almost none of the sharpening, while anything several times above
    # it takes nearly all.
    MASK_GAIN = 8.0
    MASK_SIGMA = 3.0

    # Where the fade toward white starts and where it has finished, in display
    # luma. A halo is worst of all against a blown highlight.
    HIGHLIGHT_START = 0.82
    HIGHLIGHT_END = 1.0

    DX = Vips::Image.new_from_array([[-0.5, 0.0, 0.5]]).freeze
    DY = Vips::Image.new_from_array([[-0.5], [0.0], [0.5]]).freeze

    # One tile's statistics: its grain energy, its edge energy per axis at the
    # fine and the coarse scale, and how bright it is.
    Tile = Data.define(:noise, :fine, :coarse, :mean)

    # What a frame turned out to be. `grain` is a luma sigma in 0..1, `blur`
    # the softness of its edges in pixels, `edge` its edge energy as a multiple
    # of its grain floor, and `floor` and `radius` are what the sharpening
    # needs: the energy a flat piece of the frame holds, and the radius that
    # matches how soft it is.
    Measurement = Data.define(:grain, :blur, :edge, :floor, :radius, :sharpenable) do
      def report
        format("  grain %.4f   softness %.2f px   edges %.0fx grain%s", grain, blur, edge,
               sharpenable ? format("   sharpen at %.2f px", radius) : "   (left alone)")
      end
    end

    # What a frame too small to hold a tile comes back as.
    NOTHING = Measurement.new(grain: 0.0, blur: 0.0, edge: 0.0, floor: 0.0, radius: 0.0,
                              sharpenable: false)

    class << self
      # Expects a float sRGB image in 0..1 with three bands.
      def measure(image)
        fine = sigma(FINE_SIGMA, image)
        coarse = fine * COARSE_RATIO
        luma = Colour.clamp01(luma_of(image))
        tiles = tile_stats(inset(luma), fine, coarse, sigma(GRAIN_SIGMA, image))
        return NOTHING if tiles.empty?

        widths = axes(tiles).map { |pair| softness(*pair, fine, coarse) }
        signal, _, floor = above_floor(tiles, ->(t) { t.fine.sum }, ->(t) { t.coarse.sum })
        # A frame with no grain in it at all divides by nothing, and every edge
        # it has counts.
        edge = signal / [floor, Float::EPSILON].max

        Measurement.new(grain: Math.sqrt(quantile(tiles.map(&:noise), QUIET_PCT)),
                        blur: widths.max, edge: edge, floor: floor,
                        radius: widths.min.clamp(fine * MIN_RADIUS, fine * MAX_RADIUS),
                        sharpenable: edge >= MIN_EDGE && widths.max <= fine * MAX_BLUR)
      end

      # A sharpened copy, or the frame as it came when sharpening it would only
      # find grain. `amount` is a 0..1 strength from the command line.
      def sharpen(image, measured, amount)
        return image if amount <= 0 || !measured.sharpenable

        luma = Colour.clamp01(luma_of(image))
        soft = luma.gaussblur(measured.radius)
        gain = amount * GAIN * GRAIN_KNEE / (GRAIN_KNEE + measured.grain)
        lift = (luma - soft) * gain * edge_mask(luma, measured, sigma(FINE_SIGMA, image)) *
               taper(soft)
        # The same lift in all three channels: sharpening the colour apart from
        # the brightness is what turns film grain into coloured speckle.
        Colour.clamp01(image + lift).copy(interpretation: :srgb)
      end

      private

      # Squared gradient, which adds up across independent sources, so the
      # grain floor can be taken off the top of a busy tile rather than modelled.
      def edge_energy(image)
        dx, dy = gradients(image)
        dx * dx + dy * dy
      end

      def gradients(image)
        [image.conv(DX, precision: :float), image.conv(DY, precision: :float)]
      end

      # Grain, edge energy along both axes at both scales, and brightness, per
      # tile, in one pass over the frame. Everything larger than these few
      # thousand numbers is left to vips; the statistics are plain Ruby.
      def tile_stats(luma, fine, coarse, grain_sigma)
        size = tile_size(luma)
        return [] if luma.width < size || luma.height < size

        high_pass = luma - luma.gaussblur(grain_sigma)
        bands = [high_pass * high_pass]
        [fine, coarse].each do |s|
          bands.concat(gradients(luma.gaussblur(s)).map { |g| g * g })
        end
        bands << luma

        width = (luma.width / size) * size
        height = (luma.height / size) * size
        grid = bands.first.bandjoin(bands.drop(1)).extract_area(0, 0, width, height)
                    .shrink(size, size)
        # Cast before reading it back: a frame that reached here through the
        # colour work is double, and unpacking that as float returns nonsense.
        rows = grid.cast(:float).write_to_memory.unpack("f*").each_slice(bands.size).map do |t|
          Tile.new(noise: t[0], fine: [t[1], t[2]], coarse: [t[3], t[4]], mean: t[5])
        end

        usable = rows.select { |t| t.mean.between?(DARK, BRIGHT) }
        # A frame that lives entirely in the highlights still has to be
        # measured on something.
        usable.size < MIN_TILES ? rows : usable
      end

      def tile_size(luma)
        [Math.sqrt(luma.width * luma.height / TARGET_TILES.to_f).round, MIN_TILE].max
      end

      # Each axis that has real edges of its own to judge softness by. Read
      # apart, since a frame that moved sideways keeps its horizontal edges and
      # would pass as sharp if both axes were counted together.
      def axes(tiles)
        measured = [0, 1].map do |i|
          above_floor(tiles, ->(t) { t.fine[i] }, ->(t) { t.coarse[i] })
        end
        kept = measured.select do |signal, _, floor|
          signal.positive? && signal >= floor * MIN_EDGE
        end
        (kept.empty? ? measured : kept).map { |signal, coarse, _| [signal, coarse] }
      end

      # How far the busiest tiles rise above the grain floor, at both scales.
      # The same tiles are read at both, so the two are comparable.
      def above_floor(tiles, fine, coarse)
        floor = quantile(tiles.map(&fine), QUIET_PCT)
        coarse_floor = quantile(tiles.map(&coarse), QUIET_PCT)
        keep = [(tiles.size * (100 - EDGE_PCT) / 100.0).round, 1].max
        top = tiles.sort_by(&fine).last(keep)
        [[mean_of(top, fine) - floor, 0.0].max,
         [mean_of(top, coarse) - coarse_floor, 0.0].max, floor]
      end

      def quantile(values, pct)
        [Measurements.percentile(values.sort, pct), 0.0].max
      end

      def mean_of(tiles, pick)
        tiles.sum(&pick) / tiles.size
      end

      # The edge width that explains how much energy the coarser scale lost. An
      # edge of width b read at scale s carries energy in proportion to
      # 1/sqrt(b^2 + s^2), so the ratio between the two scales gives b.
      def softness(signal, coarse_signal, fine, coarse)
        return BLUR_CEILING if signal <= 0

        ratio = (coarse_signal / signal)**2
        return BLUR_CEILING if ratio >= 1.0

        squared = (ratio * coarse**2 - fine**2) / (1.0 - ratio)
        squared <= 0 ? 0.0 : Math.sqrt(squared).clamp(0.0, BLUR_CEILING)
      end

      # Where the frame has real edges, as a 0..1 weight, so flat sky does not
      # come back crunchy. Read off a blurred copy, or the grain would draw a
      # mask of its own.
      def edge_mask(luma, measured, fine)
        energy = edge_energy(luma.gaussblur(fine)).gaussblur(fine * MASK_SIGMA)
        floor = [measured.floor * MASK_GAIN, 1e-9].max
        # Squared, so the step from grain to detail is taken in one go rather
        # than as a long ramp that hands half the sharpening to flat sky.
        (energy * energy) / (energy * energy + floor * floor)
      end

      # The fade toward white, smooth at both ends so it leaves no seam of its
      # own across a bright wall.
      def taper(soft)
        room = soft.linear(-1.0, HIGHLIGHT_END) / (HIGHLIGHT_END - HIGHLIGHT_START)
        t = Colour.clamp01(room)
        t * t * t.linear(-2.0, 3.0)
      end

      def inset(image)
        dx = (image.width * INSET).to_i
        dy = (image.height * INSET).to_i
        return image if image.width - 2 * dx < MIN_TILE || image.height - 2 * dy < MIN_TILE

        image.extract_area(dx, dy, image.width - 2 * dx, image.height - 2 * dy)
      end

      def sigma(base, image)
        [base * image.width / FULL_WIDTH, MIN_SIGMA].max
      end

      def luma_of(image)
        (image * LUMA).bandmean * 3.0
      end
    end
  end
end
