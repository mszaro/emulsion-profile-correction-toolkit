module Emulsion
  # Colour correction for films the scanner had no profile for, toward how a
  # reference film renders neutral when scanned properly.
  #
  # A scan made with another film's profile leaves each channel with its own
  # black floor and its own curve, so a grey wall comes out a different colour
  # at every brightness. The correction comes in three layers: the film's own
  # cast, fitted once from several rolls and kept in its profile; how this
  # roll's lab session drifted from that; and how each frame drifted from the
  # roll. Each measures what neutral looks like at each tone and bends red and
  # blue against green until it matches the reference.
  class ColourBalance
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Tone bands as linear luma, roughly a stop and a half apart.
    TONES = [0.003, 0.008, 0.02, 0.05, 0.1, 0.2, 0.4, 0.7].freeze
    LOG_TONES = TONES.map { |t| Math.log(t) }.freeze

    # Pixels a band needs before its colour is trusted, across a roll and in
    # a single frame.
    ROLL_MIN_PIXELS = 1500
    FRAME_MIN_PIXELS = 400

    # The share of a band, nearest its current centre, averaged as its neutral.
    NEAREST_PCT = 30

    # A pixel with any channel this close to white, in linear light, has been
    # clipped by the scanner. Clipped whites read as neutral whatever the cast,
    # so they are left out of every measurement.
    CLIPPED = 0.95

    # Pixels change band as the gains land, so the film fit measures again:
    # first from each band's typical colour, then from the greys nearest neutral.
    MEDIAN_ROUNDS = 2
    NEAREST_ROUNDS = 4
    DRIFT_ROUNDS = 3

    # The most the film fit moves any channel at one tone, in stops, and the
    # default limits on how far a roll and a frame may drift from it.
    ROLL_MAX_STOPS = 3.5
    ROLL_LIMIT = 1.0
    FRAME_MAX_STOPS = 2.5

    # The drift fit's tilt, in stops per e-fold of luma: at most 3 stops of
    # difference between the darkest and brightest bands.
    MAX_TILT = 0.55

    # In the drift fit, bands further than HUBER stops from the line count for
    # less, and bands further than TUKEY stops do not count at all.
    HUBER = 0.35
    TUKEY = 1.2

    ROLL_PIXELS = 250_000
    FRAME_PIXELS = 100_000

    attr_reader :offsets, :gains

    # Fits a film's own cast from several of its rolls pooled, so that no one
    # roll's scenes set it: a roll of warm sandstone should not teach the fit
    # that the film scans warm. Returns per-tone gains in stops, [red, green,
    # blue], for the profile's film_gains, measured on pixels with each roll's
    # black floors already removed.
    def self.fit_film(samples, target)
      pixels = samples.flat_map do |sample|
        roll = linear_pixels(sample, black_offsets(sample))
        roll.each_slice([roll.size * samples.size / ROLL_PIXELS, 1].max).map(&:first)
      end
      gains = Array.new(TONES.size) { [0.0, 0.0, 0.0] }
      # The first rounds take out the gross cast from each band's typical colour.
      # Once it is small, the later ones settle on the greys nearest neutral,
      # since a band's typical colour is whatever fills it, such as sky.
      (MEDIAN_ROUNDS + NEAREST_ROUNDS).times do |round|
        from = round < MEDIAN_ROUNDS ? nil : target
        corrected = new([0, 0, 0], gains).correct_linear(pixels)
        measured = measure_bands(corrected, ROLL_MIN_PIXELS, from: from).map { |band| band && band[:centre] }
        break if measured.compact.size < 2

        step = gains_toward(fill_gaps(measured), target)
        gains = gains.zip(step).map do |total, delta|
          total.zip(delta).map { |a, b| (a + b).clamp(-ROLL_MAX_STOPS, ROLL_MAX_STOPS) }
        end
      end
      gains.map { |g| g.map { |v| v.round(3) } }
    end

    # Fits one roll. With the film's gains from its profile, the roll only adds
    # a smooth correction of up to `limit` stops for how this lab session
    # drifted. Without them the roll is fitted as a film of its own.
    def self.fit_roll(sample, target, film: nil, limit: ROLL_LIMIT)
      offsets = black_offsets(sample)
      return new(offsets, fit_film([sample], target)) unless film

      pixels = new([0, 0, 0], film).correct_linear(linear_pixels(sample, offsets))
      drift = drift_gains(pixels, target, limit, ROLL_MIN_PIXELS)
      return new(offsets, film) unless drift

      new(offsets, film.zip(drift).map { |f, d| f.zip(d).map { |a, b| a + b } })
    end

    # Fits one frame, already roll balanced, as a float sRGB image, for how the
    # lab's balance drifted on this frame. Nil when too little is measured.
    def self.fit_frame(srgb, target, limit: FRAME_MAX_STOPS, skip: nil)
      gains = drift_gains(frame_pixels(srgb, skip: skip), target, limit, FRAME_MIN_PIXELS)
      gains && new([0.0, 0.0, 0.0], gains)
    end

    # Drift changes smoothly with brightness, so only a shift and a tilt across
    # the tones are fitted, robustly, from the greys nearest neutral, and a band
    # that is all sky or all foliage is outvoted by the rest. Searching out from
    # neutral stops short of a large drift, so the fit measures again after each
    # round. How far a film drifts is its own, so the total eases off toward
    # `limit` stops, which keeps a frame full of leaves from reading as a cast.
    def self.drift_gains(pixels, target, limit, minimum)
      total = Array.new(2) { Array.new(TONES.size, 0.0) }
      DRIFT_ROUNDS.times do |round|
        corrected = new([0, 0, 0], drift_to_gains(total, target)).correct_linear(pixels)
        bands = measure_bands(corrected, minimum, from: target)
        used = bands.each_index.select { |i| bands[i] }
        if used.size < 3
          return nil if round.zero?

          break
        end

        (0..1).each do |c|
          points = used.map do |i|
            [LOG_TONES[i], target[i][c] - bands[i][:centre][c], Math.sqrt(bands[i][:count])]
          end
          line = robust_line(points)
          TONES.each_index do |i|
            x = LOG_TONES[i].clamp(LOG_TONES[used.first], LOG_TONES[used.last])
            total[c][i] += line[0] + line[1] * x
          end
        end
      end
      eased = total.map { |channel| channel.map { |v| limit * Math.tanh(v / limit) } }
      drift_to_gains(eased, target)
    end

    # Gains that put the greys of already corrected pixels back on the
    # reference, tone by tone rather than as a line, since what is left after
    # the tone work is a bump in the midtones that no straight line can follow.
    # Each band is smoothed into its neighbours and the total eases off toward
    # `limit` stops.
    def self.residual_gains(pixels, target, limit, minimum)
      total = Array.new(2) { Array.new(TONES.size, 0.0) }
      DRIFT_ROUNDS.times do |round|
        corrected = new([0, 0, 0], drift_to_gains(total, target)).correct_linear(pixels)
        measured = measure_bands(corrected, minimum, from: target)
        return nil if round.zero? && measured.compact.size < 2
        break if measured.compact.size < 2

        centres = fill_gaps(measured.map { |band| band && band[:centre] })
        (0..1).each do |c|
          steps = TONES.each_index.map { |i| target[i][c] - centres[i][c] }
          smoothed = steps.each_index.map do |i|
            (steps[[i - 1, 0].max] + 2 * steps[i] + steps[[i + 1, steps.size - 1].min]) / 4.0
          end
          TONES.each_index { |i| total[c][i] += smoothed[i] }
        end
      end
      eased = total.map { |channel| channel.map { |v| limit * Math.tanh(v / limit) } }
      drift_to_gains(eased, target)
    end

    # Per-tone gains for a drift of [red, blue] stops at each tone.
    def self.drift_to_gains(drift, target)
      measured = TONES.each_index.map { |i| [target[i][0] - drift[0][i], target[i][1] - drift[1][i]] }
      gains_toward(measured, target)
    end

    def self.from_cache(data)
      new(data[:offsets], data[:gains])
    end

    # Each channel's black floor above the lowest one, in 0..255. Measured per
    # frame and the median taken, since one dark frame should not set the roll.
    def self.black_offsets(sample)
      start = 0
      floors = sample.frame_sizes.map do |size|
        range = start...(start + size)
        start += size
        [sample.r, sample.g, sample.b].map { |values| percentile(values[range], 1) }
      end
      black = (0..2).map { |c| percentile(floors.map { |f| f[c] }, 50) }
      black.map { |b| b - black.min }
    end

    # The sample in linear light with the black floors removed, strided down
    # so the fit stays quick on a long roll.
    def self.linear_pixels(sample, offsets)
      step = [sample.r.size / ROLL_PIXELS, 1].max
      (0...sample.r.size).step(step).map do |i|
        [sample.r[i], sample.g[i], sample.b[i]].each_with_index.map do |v, c|
          Colour.srgb_to_linear_scalar(remove_floor(v, offsets[c]) / 255.0)
        end
      end
    end

    # Every Nth pixel of a frame, in linear light, taken the way RollSample
    # takes them and inside the same inset.
    # `skip` is a mask of pixels that have no business in a neutral estimate,
    # a sky being the one that matters, taken at the same grid as the pixels.
    def self.frame_pixels(srgb, skip: nil)
      w = srgb.width
      h = srgb.height
      dx = (w * RollSample::INSET).to_i
      dy = (h * RollSample::INSET).to_i
      inner = srgb.extract_area(dx, dy, w - 2 * dx, h - 2 * dy)
      factor = Math.sqrt(inner.width * inner.height / FRAME_PIXELS.to_f).floor
      factor = factor > 1 ? factor : 1
      inner = inner.subsample(factor, factor) if factor > 1
      pixels = inner.cast(:float).write_to_memory.unpack("f*").each_slice(inner.bands).map do |px|
        px.first(3).map { |v| Colour.srgb_to_linear_scalar(v.clamp(0.0, 1.0)) }
      end
      return pixels unless skip

      keep = skip.extract_area(dx, dy, w - 2 * dx, h - 2 * dy)
      keep = keep.subsample(factor, factor) if factor > 1
      flags = keep.cast(:float).write_to_memory.unpack("f*")
      pixels.each_with_index.reject { |_px, i| flags[i] > 0.5 }.map(&:first)
    end

    def self.remove_floor(value, offset)
      ((value - offset) * 255.0 / (255.0 - offset)).clamp(0.0, 255.0)
    end

    # What neutral looks like at each tone, as [red, blue] stops against green,
    # or nil where a band is too sparse.
    def self.neutral_by_tone(pixels, minimum = ROLL_MIN_PIXELS, from: nil)
      measure_bands(pixels, minimum, from: from).map { |band| band && band[:centre] }
    end

    # Each band's neutral is found by averaging the pixels nearest a starting
    # colour, then again around that average. Without `from` the start is the
    # band's median colour, which finds a large cast, since picking the least
    # colourful pixels would pick scene colours opposite it. With `from`, a
    # neutral per band, the search starts there and settles on the nearest
    # greys rather than on whatever fills the band, such as sky or foliage.
    def self.measure_bands(pixels, minimum, from: nil)
      groups = Array.new(TONES.size) { [] }
      pixels.each do |px|
        next if px.min <= 1e-5 || px.max >= CLIPPED

        groups[tone_index(luma(px))] << [Math.log2(px[0] / px[1]), Math.log2(px[2] / px[1])]
      end
      groups.each_with_index.map do |g, i|
        next nil if g.size < minimum

        start = from ? from[i] : [percentile(g.map(&:first), 50), percentile(g.map(&:last), 50)]
        { centre: centre_of(g, start, from ? 4 : 2), count: g.size }
      end
    end

    def self.centre_of(group, start, rounds)
      centre = start
      rounds.times do
        dist = group.map { |r, b| (r - centre[0])**2 + (b - centre[1])**2 }
        cut = percentile(dist, NEAREST_PCT)
        near = group.each_index.select { |i| dist[i] <= cut }
        centre = [near.sum { |i| group[i][0] } / near.size, near.sum { |i| group[i][1] } / near.size]
      end
      centre
    end

    # A weighted straight line through [x, y, weight] points. Starts flat at
    # the weighted median, so an outlier cannot set the start, then refits with
    # Huber weights to find the line and Tukey weights to drop bands that are
    # still far from it. Returns [intercept, slope].
    def self.robust_line(points)
      scale = points.map { |_, _, w| w }
      xy = points.map { |x, y, _| [x, y] }
      line = [weighted_median(points.map { |_, y, w| [y, w] }), 0.0]
      [[:huber, 6], [:tukey, 6]].each do |kind, rounds|
        rounds.times do
          weights = points.each_with_index.map do |(x, y, _), i|
            scale[i] * robust_weight(kind, (y - line[0] - line[1] * x).abs)
          end
          break if weights.sum <= 1e-9

          line = weighted_line(xy, weights)
        end
      end
      mean_x = points.sum { |x, _, w| x * w } / scale.sum
      slope = line[1].clamp(-MAX_TILT, MAX_TILT)
      # Keep the line through the same point when the tilt is clamped.
      [line[0] + (line[1] - slope) * mean_x, slope]
    end

    def self.robust_weight(kind, residual)
      if kind == :huber
        residual <= HUBER ? 1.0 : HUBER / residual
      else
        residual >= TUKEY ? 0.0 : (1 - (residual / TUKEY)**2)**2
      end
    end

    def self.weighted_median(pairs)
      sorted = pairs.sort_by(&:first)
      half = sorted.sum(&:last) / 2.0
      running = 0.0
      sorted.each do |value, weight|
        running += weight
        return value if running >= half
      end
      sorted.last.first
    end

    def self.weighted_line(points, weights)
      total = weights.sum
      mx = points.each_with_index.sum { |(x, _), i| x * weights[i] } / total
      my = points.each_with_index.sum { |(_, y), i| y * weights[i] } / total
      sxx = points.each_with_index.sum { |(x, _), i| weights[i] * (x - mx)**2 }
      sxy = points.each_with_index.sum { |(x, y), i| weights[i] * (x - mx) * (y - my) }
      slope = sxx <= 1e-9 ? 0.0 : sxy / sxx
      [my - slope * mx, slope]
    end

    # Gains in stops per channel that move each measured neutral to the target,
    # scaled so a neutral at that tone keeps its brightness.
    def self.gains_toward(measured, target)
      measured.zip(target).map do |(mr, mb), (tr, tb)|
        before = LUMA[0] * 2**mr + LUMA[1] + LUMA[2] * 2**mb
        after = LUMA[0] * 2**tr + LUMA[1] + LUMA[2] * 2**tb
        green = Math.log2(before / after)
        [tr - mr + green, green, tb - mb + green]
      end
    end

    # Bands with too few pixels borrow from the nearest measured one.
    def self.fill_gaps(values)
      measured = values.each_index.select { |i| values[i] }
      values.each_index.map { |i| values[measured.min_by { |j| (j - i).abs }] }
    end

    def self.tone_index(y)
      l = Math.log([y, 1e-6].max)
      LOG_TONES.each_index.min_by { |i| (LOG_TONES[i] - l).abs }
    end

    def self.luma(px)
      LUMA[0] * px[0] + LUMA[1] * px[1] + LUMA[2] * px[2]
    end

    def self.percentile(values, pct)
      Measurements.percentile(values.sort, pct)
    end

    def initialize(offsets, gains)
      @offsets = offsets
      @gains = gains
    end

    # How much of the correction to apply, 0 to 1.
    def strength
      @strength || 1.0
    end

    def strength=(value)
      @strength = value
      @luts = nil
    end

    # How far a pixel may be pulled down, in stops, when a gain would take it
    # past white. Zero clips instead, which is what happens to a sky whose
    # blue has to come up two stops.
    def headroom
      @headroom || 0.0
    end

    attr_writer :headroom

    def applied_offsets
      @offsets.map { |o| o * strength }
    end

    def applied_gains
      @gains.map { |g| g.map { |v| v * strength } }
    end

    # Gains in stops at one linear luma, interpolated between the tone bands.
    def gain_at(y, gains = applied_gains)
      return gains.first if y <= TONES.first
      return gains.last if y >= TONES.last

      l = Math.log(y)
      hi = LOG_TONES.index { |t| t >= l }
      t = (l - LOG_TONES[hi - 1]) / (LOG_TONES[hi] - LOG_TONES[hi - 1])
      (0..2).map { |c| gains[hi - 1][c] * (1 - t) + gains[hi][c] * t }
    end

    # The correction on linear pixels without their floors, as the fit sees them.
    def correct_linear(pixels)
      gains = applied_gains
      pixels.map do |px|
        g = gain_at(self.class.luma(px), gains)
        (0..2).map { |c| (px[c] * 2**g[c]).clamp(0.0, 1.0) }
      end
    end

    # The correction on a float sRGB image in 0..1. Gains are indexed on
    # blurred luma, so neighbouring grains get the same gain.
    def apply(srgb)
      image = srgb
      if applied_offsets.any?(&:positive?)
        off = applied_offsets.map { |o| o / 255.0 }
        image = Colour.clamp01((image - off) / off.map { |o| 1.0 - o })
      end
      linear = Colour.to_linear(image)
      guide = ((linear * LUMA).bandmean * 3.0).gaussblur(2.0)
      index = (Colour.to_srgb(guide) * 255.0).cast(:uchar)
      bands = (0..2).map { |c| linear[c] * index.maplut(luts[c]) }
      corrected = Highlights.pull(bands[0].bandjoin([bands[1], bands[2]]), headroom)
      Colour.to_srgb(corrected).copy(interpretation: :srgb)
    end

    # The same correction on a roll sample, so later roll fits see the
    # balanced roll.
    def apply_to_sample(sample)
      off = applied_offsets
      gains = applied_gains
      r = []
      g = []
      b = []
      y = []
      sample.r.each_index do |i|
        px = [sample.r[i], sample.g[i], sample.b[i]].each_with_index.map do |v, c|
          Colour.srgb_to_linear_scalar(self.class.remove_floor(v, off[c]) / 255.0)
        end
        gain = gain_at(self.class.luma(px), gains)
        out = (0..2).map { |c| encode((px[c] * 2**gain[c]).clamp(0.0, 1.0)) * 255.0 }
        r << out[0]
        g << out[1]
        b << out[2]
        y << self.class.luma(out)
      end
      RollSample::Pixels.new(r: r, g: g, b: b, y: y, frame_sizes: sample.frame_sizes)
    end

    # The same fit with another set of black floors, for a frame whose own
    # floors were read off the film rebate.
    def with_offsets(offsets)
      copy = self.class.new(offsets, @gains)
      copy.strength = strength
      copy
    end

    def to_h
      { "offsets" => @offsets, "gains" => @gains }
    end

    def report
      lines = [format("  black floors lowered   red %.1f   green %.1f   blue %.1f", *applied_offsets)]
      applied_gains.each_with_index do |(r, g, b), i|
        lines << format("  tone %.3f   red %+.2f   green %+.2f   blue %+.2f stops", TONES[i], r, g, b)
      end
      lines.join("\n")
    end

    private

    def luts
      @luts ||= begin
        gains = applied_gains
        per_index = (0..255).map { |i| gain_at(Colour.srgb_to_linear_scalar(i / 255.0), gains) }
        (0..2).map { |c| Vips::Image.new_from_array([per_index.map { |g| 2**g[c] }]) }
      end
    end

    def encode(v)
      v <= 0.0031308 ? v * 12.92 : 1.055 * (v**(1 / 2.4)) - 0.055
    end
  end
end
