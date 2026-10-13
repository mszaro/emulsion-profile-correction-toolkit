module FilmScan
  # The look of rolls shot alongside this one, carried over as the last step
  # of the correction: how light the frames are, their average colour at each
  # brightness, and how colourful they are. Fitted once for the roll, in CIE
  # Lab, from a sample of the corrected roll and of the rolls it matches.
  class LookMatch
    # Points along the lightness distribution that are matched to each other.
    QUANTILES = (0..40).map { |i| i * 2.5 }.freeze
    # Brightness bands the average colour is read in, as L* centres, and how
    # far either side of its centre a band reaches.
    BANDS = [10, 25, 40, 55, 70, 85].freeze
    BAND_REACH = 10
    # Fewest pixels a band needs on both sides before its colour is believed.
    MIN_BAND = 500
    # The colour moves less in the shadows and not at all in deep shadow: a
    # dark interior has nothing to learn from a roll of sunlit streets.
    SHADOW = [12.0, 35.0].freeze
    # How far the colourfulness may be scaled either way.
    SPREAD_LIMIT = [0.7, 1.6].freeze
    # Pixels read from a frame for the fit.
    PER_FRAME = 20_000
    # A frame this dark at its median, in L*, is a dark scene rather than a
    # dark rendering: a church interior or a night street keeps its own look.
    # The match eases in between the two and is whole above the second.
    LOW_KEY = [15.0, 35.0].freeze

    attr_reader :lightness, :offsets, :spread, :strength

    # Lab pixels, as [[L, a, b], ...], for the corrected roll and for the
    # rolls it matches.
    def self.fit(film, target)
      lightness = quantiles(film.map(&:first)).zip(quantiles(target.map(&:first)))
      spread = (chroma_spread(target) / [chroma_spread(film), 1e-6].max).clamp(*SPREAD_LIMIT)
      offsets = BANDS.map do |centre|
        from = in_band(film, centre)
        to = in_band(target, centre)
        next nil if from.size < MIN_BAND || to.size < MIN_BAND

        [1, 2].map { |c| mean(to, c) - spread * mean(from, c) }
      end
      new(lightness: lightness, offsets: fill(offsets), spread: spread)
    end

    # Lab pixels from a float sRGB image, about count of them, and fewer from
    # a frame dark enough that the match mostly leaves it alone.
    def self.pixels(srgb, count = PER_FRAME, weighted: true)
      scale = Math.sqrt(count.to_f / (srgb.width * srgb.height))
      small = scale < 1.0 ? srgb.resize(scale) : srgb
      pixels = lab_of(small).write_to_memory.unpack("f*").each_slice(3).to_a
      return pixels unless weighted

      keep = (pixels.size * key_weight(median_of(pixels))).round
      keep.zero? ? [] : pixels.each_slice((pixels.size.to_f / keep).ceil).map(&:first)
    end

    # How much of the match a frame takes, by its median lightness.
    def self.key_weight(median)
      t = ((median - LOW_KEY[0]) / (LOW_KEY[1] - LOW_KEY[0])).clamp(0.0, 1.0)
      t * t * (3 - 2 * t)
    end

    def self.median_of(pixels)
      return 0.0 if pixels.empty?

      pixels.map(&:first).sort[pixels.size / 2]
    end

    # A frame's median lightness, read from a small copy.
    def self.key_of(srgb)
      median_of(pixels(srgb, 4000, weighted: false))
    end

    def self.lab_of(srgb)
      Colour.to_linear(srgb).copy(interpretation: :scrgb).colourspace(:lab).cast(:float)
    end

    def self.from_cache(data)
      new(lightness: data[:lightness], offsets: data[:offsets], spread: data[:spread])
    end

    def self.quantiles(values)
      sorted = values.sort
      QUANTILES.map { |q| sorted[((sorted.size - 1) * q / 100.0).round] }
    end

    def self.in_band(pixels, centre)
      pixels.select { |l, _, _| (l - centre).abs <= BAND_REACH }
    end

    def self.mean(pixels, channel)
      pixels.sum { |px| px[channel] } / pixels.size
    end

    # How far colour sits from its band's average, all bands pooled.
    def self.chroma_spread(pixels)
      squares = BANDS.flat_map do |centre|
        band = in_band(pixels, centre)
        next [] if band.size < MIN_BAND

        means = [mean(band, 1), mean(band, 2)]
        band.map { |_, a, b| (a - means[0])**2 + (b - means[1])**2 }
      end
      squares.empty? ? 1.0 : Math.sqrt(squares.sum / squares.size)
    end

    # A band with too few pixels takes its nearest neighbour's offset.
    def self.fill(offsets)
      known = offsets.each_index.reject { |i| offsets[i].nil? }
      return Array.new(offsets.size) { [0.0, 0.0] } if known.empty?

      offsets.each_index.map { |i| offsets[known.min_by { |k| (k - i).abs }].dup }
    end

    def initialize(lightness:, offsets:, spread:)
      @lightness = lightness
      @offsets = offsets
      @spread = spread
      @strength = 1.0
    end

    def strength=(value)
      @strength = value.to_f.clamp(0.0, 1.0)
      @tables = nil
    end

    # The frame's key is read from picture, which is the frame without any
    # border it was kept with.
    def apply(srgb, picture = srgb)
      strength = @strength * self.class.key_weight(self.class.key_of(picture))
      return srgb if strength <= 0

      lab = self.class.lab_of(srgb)
      index = (lab[0] < 0).ifthenelse(0, (lab[0] > 99.999).ifthenelse(99.999, lab[0]))
      low = index.floor
      frac = index - low
      below = low.cast(:uchar)
      above = (low + 1).cast(:uchar)
      read = ->(table) { below.maplut(table) * (frac * -1 + 1) + above.maplut(table) * frac }
      light, weight, a_off, b_off = tables(strength).map { |table| read.call(table) }
      moved = [lab[1], lab[2]].zip([a_off, b_off]).map do |channel, offset|
        channel + weight * (channel * (@spread - 1.0) + offset)
      end
      back = light.bandjoin(moved).copy(interpretation: :lab).colourspace(:scrgb)
      Colour.to_srgb(back).copy(interpretation: :srgb)
    end

    def to_h
      # Copies, so a shared row is never written as a YAML alias, which the
      # cache refuses to read.
      { "lightness" => @lightness.map(&:dup), "offsets" => @offsets.map(&:dup), "spread" => @spread }
    end

    def report
      median = @lightness[@lightness.size / 2]
      mid = @offsets[BANDS.index(55)]
      format("  matching the look: median lightness %.0f -> %.0f, midtone colour a* %+.1f b* %+.1f, " \
             "colourfulness x%.2f, at %.0f%% strength; frames darker than L* %.0f at their " \
             "median keep their own look", *median, *mid, @spread, @strength * 100, LOW_KEY[0])
    end

    private

    # Lookup tables over L* 0..100: the new lightness, how much of the colour
    # move each brightness takes, and the colour offsets, all with the
    # strength already in them.
    def tables(strength)
      (@tables ||= {})[strength.round(3)] ||= begin
        steps = (0..100).map(&:to_f)
        light = steps.map { |x| x + (lightness_at(x) - x) * strength }
        weight = steps.map { |x| shadow_weight(x) * strength }
        offset = (0..1).map { |c| steps.map { |x| offset_at(x, c) } }
        [light, weight, *offset].map { |values| Vips::Image.new_from_array([values]).cast(:float) }
      end
    end

    # Piecewise linear through the matched quantiles, carried on past the ends
    # by the nearest pair's difference.
    def lightness_at(x)
      pairs = @lightness.chunk_while { |p, q| (q[0] - p[0]).abs < 1e-6 }.map(&:first)
      return x + pairs.first[1] - pairs.first[0] if x <= pairs.first[0]
      return x + pairs.last[1] - pairs.last[0] if x >= pairs.last[0]

      upper = pairs.index { |from, _| from >= x }
      (f0, t0), (f1, t1) = pairs[upper - 1], pairs[upper]
      (t0 + (x - f0) / (f1 - f0) * (t1 - t0)).clamp(0.0, 100.0)
    end

    def offset_at(x, channel)
      return @offsets.first[channel] if x <= BANDS.first
      return @offsets.last[channel] if x >= BANDS.last

      upper = BANDS.index { |centre| centre >= x }
      t = (x - BANDS[upper - 1]) / (BANDS[upper] - BANDS[upper - 1]).to_f
      @offsets[upper - 1][channel] * (1 - t) + @offsets[upper][channel] * t
    end

    def shadow_weight(x)
      t = ((x - SHADOW[0]) / (SHADOW[1] - SHADOW[0])).clamp(0.0, 1.0)
      t * t * (3 - 2 * t)
    end
  end
end
