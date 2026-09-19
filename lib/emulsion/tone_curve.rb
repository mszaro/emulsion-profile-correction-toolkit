module Emulsion
  # The roll-wide tone correction for films the scanner had no profile for.
  #
  # A wrong profile can bunch a film's tones as well as tint them: Phoenix
  # comes back with its highlights crammed into the top few levels and its
  # midtones pushed up to meet them. Stretching each frame's black and white
  # points cannot fix the shape in between, so this measures where a roll's
  # tones typically fall once stretched and bends them toward where the
  # reference film's fall.
  class ToneCurve
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Where the shape is measured, as percentiles of luma.
    QUANTILES = [1, 5, 10, 25, 50, 75, 90, 95, 99].freeze

    # The shape is measured on each frame stretched between these, so it does
    # not depend on how dark or bright the lab left the frame.
    BLACK = 0.4
    WHITE = 99.7

    # Steepest and shallowest the curve may get, so it neither magnifies grain
    # nor flattens a range of tones into a few levels.
    MAX_SLOPE = 2.5
    MIN_SLOPE = 0.35

    LUT_SIZE = 1024

    attr_reader :from, :to

    # Each frame's luma quantiles within its own stretch, the median taken
    # across frames so one odd frame cannot set the roll's shape.
    def self.shape_of(sample)
      start = 0
      shapes = sample.frame_sizes.map do |size|
        lumas = sample.y[start, size].sort
        start += size
        lo = Measurements.percentile(lumas, BLACK)
        hi = Measurements.percentile(lumas, WHITE)
        span = [hi - lo, 1.0].max
        QUANTILES.map { |q| ((Measurements.percentile(lumas, q) - lo) / span).clamp(0.0, 1.0) }
      end
      QUANTILES.each_index.map do |i|
        Measurements.percentile(shapes.map { |s| s[i] }.sort, 50).round(4)
      end
    end

    def self.fit(sample, target)
      new(shape_of(sample), target)
    end

    def self.from_cache(data)
      new(data[:from], data[:to])
    end

    def initialize(from, to)
      @from = from
      @to = to
    end

    # How much of the correction to apply, 0 to 1. The curve may use less, if
    # the full amount would be steeper or flatter than the slope limits.
    def strength
      @strength || 1.0
    end

    def strength=(value)
      @strength = value
      @lut = nil
    end

    # The strength actually used, the most up to the requested one that keeps
    # every stretch of the curve within the slope limits.
    def effective_strength
      steps = 256
      curve = (0..steps).map { |i| interpolate(i / steps.to_f) }
      slopes = curve.each_cons(2).map { |a, b| (b - a) * steps }
      slopes.reduce(strength) do |k, s|
        # The blended slope is 1 + k * (s - 1); keep it inside the limits.
        if s > MAX_SLOPE then [k, (MAX_SLOPE - 1) / (s - 1)].min
        elsif s < MIN_SLOPE then [k, (1 - MIN_SLOPE) / (1 - s)].min
        else k
        end
      end
    end

    # Applied to a float sRGB image in 0..1, after the frame's own black and
    # white stretch. Brightness moves and the colour ratios stay, since running
    # the curve down each channel would multiply any tint still in the frame.
    def apply(image)
      image = Colour.clamp01(image)
      y = (image * LUMA).bandmean * 3.0
      safe = (y < 1e-4).ifthenelse(1e-4, y)
      Colour.clamp01(image * (curve_of(y) / safe)).copy(interpretation: :srgb)
    end

    # The curve read off the lookup table, interpolated between its entries.
    def curve_of(image)
      scaled = Colour.clamp01(image) * (LUT_SIZE - 1)
      lo = scaled.floor
      frac = scaled - lo
      lo = lo.cast(:ushort)
      hi = (lo + 1).cast(:ushort)
      lo.maplut(lut) + (hi.maplut(lut) - lo.maplut(lut)) * frac
    end

    # The curve at one point, blended with no change by the effective strength.
    def at(x, k = effective_strength)
      x + k * (interpolate(x) - x)
    end

    def to_h
      { "from" => @from, "to" => @to }
    end

    def report
      k = effective_strength
      marks = [0.1, 0.25, 0.5, 0.75, 0.9].map { |x| format("%.2f->%.2f", x, at(x, k)) }
      format("  tone curve at %.2f strength   %s", k, marks.join("   "))
    end

    private

    # The measured shape as knots from (0, 0) to (1, 1), dropping any that
    # would make the curve run backwards.
    def knots
      points = [[0.0, 0.0]]
      @from.zip(@to).each do |x, y|
        next unless x > points.last[0] + 1e-3 && y > points.last[1] && x < 1.0 && y < 1.0

        points << [x, y]
      end
      points << [1.0, 1.0]
    end

    # Monotone cubic through the knots (Fritsch and Carlson), so the curve is
    # smooth and never turns back on itself.
    def interpolate(x)
      pts = knots
      i = (0...(pts.size - 1)).find { |j| x <= pts[j + 1][0] } || (pts.size - 2)
      (x0, y0), (x1, y1) = pts[i], pts[i + 1]
      h = x1 - x0
      t = (x - x0) / h
      m0, m1 = tangents[i], tangents[i + 1]
      h00 = 2 * t**3 - 3 * t**2 + 1
      h10 = t**3 - 2 * t**2 + t
      h01 = -2 * t**3 + 3 * t**2
      h11 = t**3 - t**2
      h00 * y0 + h10 * h * m0 + h01 * y1 + h11 * h * m1
    end

    def tangents
      @tangents ||= begin
        pts = knots
        deltas = pts.each_cons(2).map { |(x0, y0), (x1, y1)| (y1 - y0) / (x1 - x0) }
        m = pts.each_index.map do |i|
          if i.zero? then deltas.first
          elsif i == pts.size - 1 then deltas.last
          elsif deltas[i - 1] * deltas[i] <= 0 then 0.0
          else (deltas[i - 1] + deltas[i]) / 2.0
          end
        end
        deltas.each_with_index do |d, i|
          next if d.zero?

          a = m[i] / d
          b = m[i + 1] / d
          s = a * a + b * b
          next unless s > 9

          tau = 3 / Math.sqrt(s)
          m[i] = tau * a * d
          m[i + 1] = tau * b * d
        end
        m
      end
    end

    def lut
      @lut ||= begin
        k = effective_strength
        values = Array.new(LUT_SIZE) { |i| at(i / (LUT_SIZE - 1).to_f, k) }
        Vips::Image.new_from_array([values])
      end
    end
  end
end
