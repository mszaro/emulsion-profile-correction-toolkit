module Emulsion
  # Everything the pipeline needs to know about a frame before it touches it,
  # measured on a sample of its pixels rather than all 25 million.
  class Measurements
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Scans often include a bright scanner border, which would drag the white
    # point up, so measurements stay inside a 5% inset.
    INSET = 0.05

    # Every Nth pixel rather than a scaled-down copy. Scaling averages
    # neighbours and pulls in the tails that the black and white points need.
    TARGET_SAMPLES = 300_000

    attr_reader :pixels, :lumas

    # Expects a float sRGB image in 0..1, which is what the whole pipeline uses.
    def initialize(image, target: TARGET_SAMPLES)
      w = image.width
      h = image.height
      dx = (w * INSET).to_i
      dy = (h * INSET).to_i
      inner = image.extract_area(dx, dy, w - 2 * dx, h - 2 * dy)

      factor = Math.sqrt(inner.width * inner.height / target.to_f).floor
      factor = 1 if factor < 1
      inner = inner.subsample(factor, factor) if factor > 1

      # Kept in memory, since the vibrance search reuses it at every step.
      @sample_image = inner.cast(:float).copy_memory
      bands = @sample_image.bands
      raw = @sample_image.write_to_memory.unpack("f*")

      @pixels = []
      @lumas = []
      raw.each_slice(bands) do |px|
        px = px.first(3) if bands != 3
        @pixels << px
        @lumas << luma(px)
      end
    end

    def luma(px)
      LUMA[0] * px[0] + LUMA[1] * px[1] + LUMA[2] * px[2]
    end

    def saturation(px)
      mx = px.max
      mx <= 1e-6 ? 0.0 : (mx - px.min) / mx
    end

    # Per-pixel saturation, computed once for mean_saturation and neutral_at.
    def sats
      @sats ||= pixels.map { |px| saturation(px) }
    end

    # Linear interpolation between neighbouring ranks, as numpy does.
    def self.percentile(sorted, pct)
      return 0.0 if sorted.empty?
      rank = (pct / 100.0) * (sorted.size - 1)
      lo = rank.floor
      hi = rank.ceil
      return sorted[lo] if lo == hi
      sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo)
    end

    def percentile(values, pct)
      self.class.percentile(values.sort, pct)
    end

    # Black and white points, in display space. Channels share one pair by
    # default, which adds contrast without touching hue. Raising `neutral`
    # gives each channel its own, which is grey-world by another name.
    def endpoints(black_pct, white_pct, neutral, max_stretch: nil)
      sorted_luma = lumas.sort
      glo = self.class.percentile(sorted_luma, black_pct)
      ghi = self.class.percentile(sorted_luma, white_pct)

      # A frame using very little range mostly has grain to magnify, so cap
      # how far it is stretched and let it stay a little flat.
      if max_stretch && (ghi - glo) < 1.0 / max_stretch
        centre = (glo + ghi) / 2.0
        half = 1.0 / (2.0 * max_stretch)
        glo = [centre - half, 0.0].max
        ghi = [centre + half, 1.0].min
      end

      (0..2).map do |c|
        vals = pixels.map { |px| px[c] }.sort
        clo = self.class.percentile(vals, black_pct)
        chi = self.class.percentile(vals, white_pct)
        [glo + neutral * (clo - glo), ghi + neutral * (chi - ghi)]
      end
    end

    # Where the tone-dependent balance is measured, as linear luma. Packed
    # toward the dark end, where a cast moves fastest.
    TONE_ANCHORS = [0.004, 0.012, 0.032, 0.08, 0.18, 0.36, 0.65].freeze

    # How much of the measured correction each anchor gets. Midtones take less,
    # because that is where the subject is and a cast looks like warm light.
    ANCHOR_STRENGTH = [0.6, 1.0, 1.0, 0.9, 0.72, 0.65, 0.8].freeze

    # How aligned a band's colours must be to count as a cast rather than as
    # scene colour, and the least an anchor is ever trusted.
    COHERENCE_FLOOR = 0.35
    COHERENCE_FULL = 0.80
    MIN_CONFIDENCE = 0.15

    # A gain per tone anchor rather than one for the whole frame, since a cast
    # can change a lot with brightness. Each is measured from the least
    # saturated pixels near that brightness, so coloured subjects do not drag it.
    def tone_gains(strength, clamp, shadow_strength = 1.0)
      return nil if strength <= 0
      raw = TONE_ANCHORS.map { |anchor| neutral_at(anchor) }
      return nil if raw.compact.size < 2

      filled = fill_gaps(raw.map { |r| r && r[:mean] })
      confidence = fill_gaps(raw.map { |r| r && r[:confidence] })
      smoothed = smooth(filled)

      smoothed.each_with_index.map do |mean, i|
        s = strength * confidence[i] * ANCHOR_STRENGTH[i]
        s *= shadow_strength if i <= 1
        target = mean.sum / 3.0
        mean.map do |m|
          g = 1.0 + s * (target / [m, 1e-6].max - 1.0)
          g.clamp(1.0 / clamp, clamp)
        end
      end
    end

    # Mean colour of the near-neutral pixels around one brightness, and how far
    # to trust it. A cast pushes every pixel the same way while scene colour
    # points all over, so trust comes from how well the colours line up.
    # Plain index loops, since this runs over every sampled pixel per anchor.
    def neutral_at(anchor, width: 0.55, sat_pct: 30, minimum: 400)
      lo = anchor * (1.0 - width)
      hi = anchor * (1.0 + width) + 0.004

      px = pixels
      ys = lumas
      st = sats
      band = []
      band_sats = []
      i = 0
      n = ys.size
      while i < n
        y = ys[i]
        if y >= lo && y < hi
          band << px[i]
          band_sats << st[i]
        end
        i += 1
      end
      return nil if band.size < minimum

      cut = self.class.percentile(band_sats.sort, sat_pct)
      sum_r = 0.0
      sum_g = 0.0
      sum_b = 0.0
      count = 0
      j = 0
      bn = band.size
      while j < bn
        if band_sats[j] <= cut
          p = band[j]
          sum_r += p[0]
          sum_g += p[1]
          sum_b += p[2]
          count += 1
        end
        j += 1
      end
      return nil if count < minimum / 3

      mean = [sum_r / count, sum_g / count, sum_b / count]
      { mean: mean, confidence: coherence_of(band) }
    end

    # How far a band's colours agree on a direction: near 1 if every pixel's
    # colour points the same way, near 0 if they cancel out.
    def coherence_of(band)
      sum_r = 0.0
      sum_b = 0.0
      sum_len = 0.0
      count = 0
      band.each do |px|
        y = luma(px)
        next if y <= 1e-6
        dr = (px[0] - y) / y
        db = (px[2] - y) / y
        len = Math.sqrt(dr * dr + db * db)
        next if len < 1e-4
        sum_r += dr
        sum_b += db
        sum_len += len
        count += 1
      end
      return MIN_CONFIDENCE if count < 50 || sum_len <= 1e-6

      aligned = Math.sqrt(sum_r * sum_r + sum_b * sum_b) / sum_len
      ((aligned - COHERENCE_FLOOR) /
       (COHERENCE_FULL - COHERENCE_FLOOR)).clamp(MIN_CONFIDENCE, 1.0)
    end

    # Anchors with too few pixels borrow from their nearest measured neighbour.
    def fill_gaps(values)
      return values if values.all?
      out = values.dup
      out.each_index do |i|
        next if out[i]
        before = (0...i).reverse_each.find { |j| values[j] }
        after = ((i + 1)...out.size).find { |j| values[j] }
        out[i] = (before && values[before]) || (after && values[after])
      end
      out
    end

    # Take the edge off a noisy anchor. Each keeps most of its own measurement,
    # since an even average dragged shadow gains up into the midtones.
    CENTRE_WEIGHT = 0.7

    def smooth(values)
      side = (1.0 - CENTRE_WEIGHT) / 2.0
      values.each_index.map do |i|
        before = values[i - 1] if i.positive?
        after = values[i + 1]
        (0..2).map do |c|
          total = values[i][c] * CENTRE_WEIGHT
          weight = CENTRE_WEIGHT
          if before
            total += before[c] * side
            weight += side
          end
          if after
            total += after[c] * side
            weight += side
          end
          total / weight
        end
      end
    end

    def mean_saturation
      @mean_saturation ||= sats.sum / pixels.size
    end

    # The vibrance amount that lands this frame on the target saturation, found
    # by bisecting on the sampled pixels. Frames already there are left alone.
    def vibrance_for(target, knee, limit)
      return 1.0 if target <= 0 || pixels.empty?
      prepare_vibrance(knee)
      lo = 1.0
      hi = limit
      return lo if predicted_saturation(lo) >= target
      return hi if predicted_saturation(hi) <= target
      20.times do
        mid = (lo + hi) / 2.0
        predicted_saturation(mid) < target ? lo = mid : hi = mid
      end
      (lo + hi) / 2.0
    end

    # The parts of predicted_saturation that do not change with the amount,
    # built once as vips images since the bisection asks about twenty times.
    def prepare_vibrance(knee)
      return if @vibrance_knee == knee
      @vibrance_knee = knee

      img = rgb_image
      y = (img * LUMA).bandmean * 3.0
      r, g, b = img[0], img[1], img[2]
      mx = (r > g).ifthenelse(r, g)
      mx = (mx > b).ifthenelse(mx, b)
      mn = (r < g).ifthenelse(r, g)
      mn = (mn < b).ifthenelse(mn, b)

      safe_y = (y < 1e-6).ifthenelse(1e-6, y)
      ratio = ((mx - mn) / safe_y) / knee

      @vib_y = y.copy_memory
      @vib_d_hi = (mx - y).copy_memory
      @vib_d_lo = (mn - y).copy_memory
      @vib_weight = ((ratio * ratio + 1.0)**-1.0).copy_memory
      @vib_dead = (y <= 1e-6).copy_memory
    end

    # What the mean saturation would become at this vibrance amount, measured
    # in sRGB because the target is a display-space figure.
    def predicted_saturation(amount)
      k = @vib_weight * (amount - 1.0) + 1.0
      hi = Colour.to_srgb(@vib_y + @vib_d_hi * k)
      lo = Colour.to_srgb(@vib_y + @vib_d_lo * k)

      safe_hi = (hi < 1e-6).ifthenelse(1e-6, hi)
      contribution = (hi - lo) / safe_hi
      contribution = (hi <= 1e-6).ifthenelse(0.0, contribution)
      contribution = @vib_dead.ifthenelse(0.0, contribution)
      contribution.avg
    end

    def rgb_image
      @rgb_image ||= @sample_image.bands == 3 ? @sample_image : @sample_image[0..2]
    end
  end
end
