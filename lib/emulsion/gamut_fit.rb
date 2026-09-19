module Emulsion
  # Solves for the per-channel curves that reopen a roll's collapsed colour.
  #
  # A roll of varied scenes holds colour in every direction. A scan that has
  # lost a channel squashes that toward a line, so the fit adjusts red and blue
  # at a few tone bands until the roll's hue spread looks healthy again.
  class GamutFit
    SECTORS = 12
    LUMA = [0.2126, 0.7152, 0.0722].freeze
    BAND_CENTRES = [45.0, 90.0, 140.0, 190.0].freeze
    CHROMA_FLOOR = 6.0

    # Bounds, and the pull back toward doing nothing. Without a penalty the fit
    # stretches colour in every direction to buy a wider spread.
    GAIN_MIN = 0.75
    GAIN_MAX = 1.35
    PENALTY = 0.35

    # A scan fault changes smoothly with brightness, so neighbouring bands are
    # charged for disagreeing. Unconstrained, the fit zigzagged between them.
    ROUGHNESS = 2.5

    # Spread past the profile's healthy figure counts against the fit, since
    # beyond that it is inventing colour rather than recovering it.
    EXCESS = 1.5

    # How near its floor a channel sits before it counts as clipped there.
    FLOOR_LEVEL = 9.0
    FLOOR_SHARE = 0.04

    attr_reader :gains, :spread_before, :spread_after, :clipped, :damaged

    def self.from_cache(data)
      allocate.tap do |f|
        f.instance_variable_set(:@gains, data[:gains])
        f.instance_variable_set(:@clipped, data[:clipped])
        f.instance_variable_set(:@spread_before, data[:spread_before])
        f.instance_variable_set(:@spread_after, data[:spread_after])
      end
    end

    # Green is held fixed as the reference, since something has to define the
    # level. On the one film profiled so far it is also the least damaged.
    def initialize(samples, healthy_spread:, verbose: true)
      @r, @g, @b, @y = samples.r, samples.g, samples.b, samples.y
      @clipped = find_clipping
      @damaged = [@clipped.any? { |c| c[0] }, @clipped.any? { |c| c[1] }]
      @gains = Array.new(BAND_CENTRES.size) { [1.0, 1.0] }   # [red, blue] per band
      @spread_before = spread(@gains)
      # A roll already past the healthy figure is never dragged down to it.
      @ceiling = [healthy_spread, @spread_before].max
      @gains = optimise(verbose)
      @spread_after = spread(@gains)
    end

    # Which channels have hit their floor, band by band. Spread cannot tell a
    # dying channel from a strong one, so this is what stops the fit turning a
    # clipped channel down further.
    def find_clipping
      Array.new(BAND_CENTRES.size) { [false, false] }.tap do |flags|
        counts = Array.new(BAND_CENTRES.size) { [0, 0, 0] }
        @y.each_index do |i|
          band = nearest_band(@y[i])
          counts[band][0] += 1 if @r[i] < FLOOR_LEVEL
          counts[band][1] += 1 if @b[i] < FLOOR_LEVEL
          counts[band][2] += 1
        end
        counts.each_with_index do |(red, blue, total), band|
          next if total < 500

          flags[band][0] = red.to_f / total > FLOOR_SHARE
          flags[band][1] = blue.to_f / total > FLOOR_SHARE
        end
      end
    end

    def nearest_band(y)
      best = 0
      BAND_CENTRES.each_with_index do |c, i|
        best = i if (y - c).abs < (y - BAND_CENTRES[best]).abs
      end
      best
    end

    # Breadth of the hue distribution: 1.0 if colour lands in every direction
    # equally, 0 if it all points one way.
    def spread(gains)
      counts = Array.new(SECTORS, 0.0)
      total = 0.0

      @y.each_index do |i|
        gr, gb = interpolate(gains, @y[i])
        r = @r[i] * gr
        g = @g[i]
        b = @b[i] * gb

        ry = r - g
        by = b - (r + g) / 2.0
        chroma = Math.sqrt(ry * ry + by * by)
        next if chroma < CHROMA_FLOOR

        angle = Math.atan2(by, ry) + Math::PI
        sector = (angle * SECTORS / (2 * Math::PI)).to_i % SECTORS
        counts[sector] += chroma
        total += chroma
      end
      return 0.0 if total <= 0

      entropy = 0.0
      counts.each do |c|
        next if c <= 0

        p = c / total
        entropy -= p * Math.log(p)
      end
      entropy / Math.log(SECTORS)
    end

    private

    # What the fit is worth: spread bought, minus the distortion spent.
    def score(gains)
      cost = gains.sum { |gr, gb| (gr - 1.0)**2 + (gb - 1.0)**2 }

      roughness = 0.0
      gains.each_cons(2) do |a, b|
        roughness += (a[0] - b[0])**2 + (a[1] - b[1])**2
      end

      s = spread(gains)
      # A correction that narrows the colour is not a correction.
      return -Float::INFINITY if s < @spread_before - 1e-6

      excess = s > @ceiling ? (s - @ceiling) : 0.0

      s - PENALTY * cost - ROUGHNESS * roughness - EXCESS * excess
    end

    # Coordinate descent: step each gain up and down in turn and keep what
    # helps. The parameter space is small enough that nothing cleverer is needed.
    def optimise(verbose)
      best = @gains.map(&:dup)
      best_score = score(best)

      [0.08, 0.04, 0.015].each do |step|
        improved = true
        while improved
          improved = false
          best.each_index do |band|
            2.times do |which|
              [-step, step].each do |delta|
                trial = best.map(&:dup)
                # A channel clipped anywhere on the roll is never reduced
                # anywhere, or the fit just takes it out of the highlights.
                floor = @damaged[which] ? 1.0 : GAIN_MIN
                trial[band][which] = (trial[band][which] + delta).clamp(floor, GAIN_MAX)
                next if trial[band][which] == best[band][which]

                s = score(trial)
                next unless s > best_score + 1e-6

                best = trial
                best_score = s
                improved = true
              end
            end
          end
        end
        print "\r  fitting gamut, spread #{format('%.3f', spread(best))}" if verbose
      end
      puts if verbose
      best
    end

    # Gains vary with brightness, interpolated between the bands.
    def interpolate(gains, y)
      return gains.first if y <= BAND_CENTRES.first
      return gains.last if y >= BAND_CENTRES.last

      i = BAND_CENTRES.index { |c| c >= y }
      lo = BAND_CENTRES[i - 1]
      hi = BAND_CENTRES[i]
      t = (y - lo) / (hi - lo)
      [gains[i - 1][0] * (1 - t) + gains[i][0] * t,
       gains[i - 1][1] * (1 - t) + gains[i][1] * t]
    end

    public

    # How much of the fit to apply, 0 to 1. Kept apart from the fit so the fit
    # can be cached once and the strength changed freely.
    attr_writer :strength

    def strength
      @strength || 1.0
    end

    def applied_gains
      @gains.map { |gr, gb| [1.0 + (gr - 1.0) * strength, 1.0 + (gb - 1.0) * strength] }
    end

    def vips_curves
      curves.map { |c| Vips::Image.new_from_array([c]) }
    end

    # Per-channel lookups over the full 0-255 range, ready to apply.
    def curves
      gains = applied_gains
      (0..2).map do |c|
        Array.new(256) do |v|
          next 1.0 if c == 1

          gr, gb = interpolate(gains, v.to_f)
          c.zero? ? gr : gb
        end
      end
    end

    def report
      lines = [format("  colour spread %.3f -> %.3f", spread_before, spread_after)]
      applied = applied_gains
      BAND_CENTRES.each_with_index do |centre, i|
        flags = (clipped || [])[i] || [false, false]
        lines << format("  tone %3d   red %.3f%s   blue %.3f%s", centre,
                        applied[i][0], flags[0] ? " (clipped)" : "",
                        applied[i][1], flags[1] ? " (clipped)" : "")
      end
      lines.join("\n")
    end
  end
end
