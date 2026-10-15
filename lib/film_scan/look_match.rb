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
    # The most a frame's colourfulness is raised once the strength is in, as a
    # share. Boosts past about x1.3 read as bleached and oversaturated.
    MAX_BOOST = 0.3
    # Pixels read from a frame for the fit.
    PER_FRAME = 20_000
    # A frame this dark at its median, in L*, is a dark scene rather than a
    # dark rendering: a church interior or a night street keeps its own look.
    # The match eases in between the two and is whole above the second.
    LOW_KEY = [15.0, 35.0].freeze
    # A pixel the sky detector weighs above this is left out of the fit.
    SKY = 0.3

    attr_reader :lightness, :offsets, :spread, :strength

    # Lab pixels, as [[L, a, b], ...], for the corrected roll and for the
    # rolls it matches.
    # Lightness is matched over the whole picture. Colour leaves out pixels
    # marked as sky: the detector finds a clear blue sky far more readily
    # than a pale one, so leaving skies out of the lightness too would drop
    # one roll's bright end and not the other's.
    def self.fit(film, target)
      lightness = quantiles(film.map(&:first)).zip(quantiles(target.map(&:first)))
      film = film.reject { |px| sky?(px) }
      target = target.reject { |px| sky?(px) }
      spread = (chroma_spread(target) / [chroma_spread(film), 1e-6].max).clamp(*SPREAD_LIMIT)
      offsets = BANDS.map do |centre|
        from = in_band(film, centre)
        to = in_band(target, centre)
        next nil if from.size < MIN_BAND || to.size < MIN_BAND

        [1, 2].map { |c| mean(to, c) - spread * mean(from, c) }
      end
      averages = BANDS.map do |centre|
        from = in_band(film, centre)
        from.size < MIN_BAND ? nil : [mean(from, 1), mean(from, 2)]
      end
      new(lightness: lightness, offsets: fill(offsets), spread: spread, film: fill(averages))
    end

    # Lab pixels from a float sRGB image, about count of them, and fewer from
    # a frame dark enough that the match mostly leaves it alone. Pixels the
    # sky mask marks carry a fourth value of 1, so the fit can leave them out
    # of the colour: a clear blue sky over one roll and a pale one over the
    # other say nothing about how either film renders.
    def self.pixels(srgb, count = PER_FRAME, weighted: true, sky: nil)
      scale = Math.sqrt(count.to_f / (srgb.width * srgb.height))
      small = scale < 1.0 ? srgb.resize(scale) : srgb
      lab = lab_of(small)
      if sky
        marked = ((scale < 1.0 ? sky.resize(scale) : sky) > SKY).ifthenelse(1.0, 0.0)
        lab = lab.bandjoin(marked.cast(:float))
      end
      pixels = lab.write_to_memory.unpack("f*").each_slice(sky ? 4 : 3).to_a
      return pixels unless weighted

      keep = (pixels.size * key_weight(median_of(pixels))).round
      keep.zero? ? [] : pixels.each_slice((pixels.size.to_f / keep).ceil).map(&:first)
    end

    # How much of the match a frame takes, by its median lightness.
    def self.key_weight(median)
      t = ((median - LOW_KEY[0]) / (LOW_KEY[1] - LOW_KEY[0])).clamp(0.0, 1.0)
      t * t * (3 - 2 * t)
    end

    def self.sky?(pixel)
      pixel.size > 3 && pixel[3] > 0.5
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

    # Whether data read from a profile or a cache has the shape of a look.
    def self.valid?(data)
      pair = ->(x) { x.is_a?(Array) && x.size == 2 && x.all?(Numeric) }
      data.is_a?(Hash) && data[:lightness].is_a?(Array) && data[:lightness].size >= 2 &&
        data[:lightness].all?(&pair) && data[:offsets].is_a?(Array) && data[:offsets].size == BANDS.size &&
        data[:offsets].all?(&pair) && data[:spread].is_a?(Numeric) &&
        (data[:film].nil? || (data[:film].is_a?(Array) && data[:film].size == BANDS.size && data[:film].all?(&pair)))
    end

    def self.from_cache(data)
      new(lightness: data[:lightness], offsets: data[:offsets], spread: data[:spread], film: data[:film])
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

    def initialize(lightness:, offsets:, spread:, film: nil)
      @lightness = lightness
      @film = film
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
      scale = scale_for(strength)
      light, weight, a_off, b_off = tables(strength).map { |table| read.call(table) }
      moved = [lab[1], lab[2]].zip([a_off, b_off]).map do |channel, offset|
        channel + weight * (channel * (scale - 1.0) + offset)
      end
      back = light.bandjoin(moved).copy(interpretation: :lab).colourspace(:scrgb)
      Colour.to_srgb(back).copy(interpretation: :srgb)
    end

    def to_h
      # Copies, so a shared row is never written as a YAML alias, which the
      # cache refuses to read.
      { "lightness" => @lightness.map(&:dup), "offsets" => @offsets.map(&:dup), "spread" => @spread,
        "film" => @film&.map(&:dup) }.compact
    end

    def report(as: "matching the look")
      median = @lightness[@lightness.size / 2]
      # How far the midtones' average colour moves, which is the offset less
      # what the colourfulness scale already did to the film's average.
      band = BANDS.index(55)
      mid = @offsets[band].each_with_index.map { |offset, c| offset + (@spread - 1.0) * (@film ? @film[band][c] : 0.0) }
      format("  #{as}: median lightness %.0f -> %.0f, midtones move a* %+.1f b* %+.1f, " \
             "colourfulness x%.2f, at %.0f%% strength; frames darker than L* %.0f at their " \
             "median keep their own look", *median, *mid, 1.0 + @strength * (scale_for(@strength) - 1.0),
             @strength * 100, LOW_KEY[0])
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
        offset = (0..1).map { |c| steps.map { |x| offset_at(x, c, scale_for(strength)) } }
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

    # The colourfulness scale a frame gets at this strength, held so the boost
    # it ends up with is no more than MAX_BOOST.
    def scale_for(strength)
      return @spread if @spread <= 1.0 || strength <= 0

      1.0 + [@spread - 1.0, MAX_BOOST / strength].min
    end

    # A band's offset for a given scale. The fitted offsets carry the fitted
    # scale, so a smaller one moves the film's average colour by what the scale
    # no longer does, and it still lands on the matched rolls' average.
    def band_offset(band, channel, scale)
      film = @film ? @film[band][channel] : 0.0
      @offsets[band][channel] + (@spread - scale) * film
    end

    def offset_at(x, channel, scale)
      return band_offset(0, channel, scale) if x <= BANDS.first
      return band_offset(BANDS.size - 1, channel, scale) if x >= BANDS.last

      upper = BANDS.index { |centre| centre >= x }
      t = (x - BANDS[upper - 1]) / (BANDS[upper] - BANDS[upper - 1]).to_f
      band_offset(upper - 1, channel, scale) * (1 - t) + band_offset(upper, channel, scale) * t
    end

    def shadow_weight(x)
      t = ((x - SHADOW[0]) / (SHADOW[1] - SHADOW[0])).clamp(0.0, 1.0)
      t * t * (3 - 2 * t)
    end
  end
end
