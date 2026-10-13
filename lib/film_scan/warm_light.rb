module FilmScan
  # Light that is warm on purpose. The frame balance reads lamps, dusk and
  # low sun as a cast like any other and takes them out.
  #
  # Lamps against a dusk sky can be found: they light the bright tones warm
  # and leave the dark ones blue, a strong tilt in the neutral estimate that a
  # roll's daylight frames do not share, and they only win when the ambient
  # light is low. Sunlit golden hour cannot be told from a lab cast by any
  # pixel measured so far, so a frame's override has to ask for it.
  module WarmLight
    module_function

    # The path from daylight to tungsten, in stops of red and blue against
    # green: blue falls about 1.7 stops for every stop red rises.
    AXIS = [0.5, -Math.sqrt(0.75)].freeze

    # Where a frame starts and finishes reading as lamp lit: its tilt against
    # the roll's typical tilt, in stops per e-fold of luma, and its median
    # display luma, lamp lit below the second. Set on 21 lamp frames against
    # 388 daylight, golden hour and sunset frames.
    TILT = [0.2, 0.4].freeze
    KEY = [0.45, 0.30].freeze

    # A frame with a large patch of white in every channel has daylight in it,
    # an overcast sky, and lamps at dusk leave nothing that white but the
    # bulbs. Dark buildings shot upward against a blown sky pass the two tests
    # above, and on 14 rolls from a December trip held 7 to 47% of their frame
    # at this white where no lamp lit frame held more than 6.4%.
    WHITE = [0.10, 0.06].freeze
    NEAR_WHITE = 0.85

    # Measured at one size, so that grain does not move the answer.
    WORK = 1500

    # How sure the frame is that its warmth is lamplight, 0 to 1. `srgb` is
    # the frame as the frame balance sees it, and `roll_tilt` the median of
    # `tilt` across the roll.
    def confidence(srgb, target, roll_tilt)
      return 0.0 unless roll_tilt

      # Worked out once, since each reading below would shrink the frame again.
      small = at_work_size(srgb).copy_memory
      tilt = tilt_of(small, target)
      return 0.0 unless tilt

      ramp(tilt - roll_tilt, *TILT) * ramp(key_of(small), *KEY) * ramp(white_of(small), *WHITE)
    end

    # How much warmer against the reference the frame's greys get per e-fold
    # of brightness, from the same neutral estimate the frame balance fits.
    # Nil when too few tones are measured.
    def tilt(srgb, target)
      tilt_of(at_work_size(srgb), target)
    end

    # Across that path, from green toward magenta.
    TINT = [-AXIS[1], AXIS[0]].freeze

    # The fit with its move toward magenta held to `limit` stops at every tone.
    # A frame of leaves reads to the fit as a green cast: on Lucky it moved a
    # park more than a stop toward magenta, where 95% of the film's frames
    # move under half a stop.
    def cap_tint(fit, limit)
      gains = fit.gains.map do |r, g, b|
        over = [(r - g) * TINT[0] + (b - g) * TINT[1] - limit, 0.0].max
        [r - over * TINT[0], g, b - over * TINT[1]]
      end
      ColourBalance.new(fit.offsets, gains)
    end

    # The fit with `share` of its move toward daylight taken off at every
    # tone, and its tint left as it was. A tone the fit warms is left alone:
    # on LomoChrome's daylight frames the fit warms blue shade, and nothing
    # here is evidence against that.
    def hold(fit, share)
      gains = fit.gains.map do |r, g, b|
        along = [(r - g) * AXIS[0] + (b - g) * AXIS[1], 0.0].min
        [r - share * along * AXIS[0], g, b - share * along * AXIS[1]]
      end
      ColourBalance.new(fit.offsets, gains)
    end

    def tilt_of(srgb, target)
      bands = ColourBalance.measure_bands(ColourBalance.frame_pixels(srgb), ColourBalance::FRAME_MIN_PIXELS,
                                          from: target)
      # The darkest band is left out: it is mostly the scanner's floor.
      used = (1...bands.size).select { |i| bands[i] }
      return nil if used.size < 3

      points = used.map do |i|
        warmth = (bands[i][:centre][0] - target[i][0]) - (bands[i][:centre][1] - target[i][1])
        [ColourBalance::LOG_TONES[i], warmth, Math.sqrt(bands[i][:count])]
      end
      ColourBalance.robust_line(points)[1]
    end

    def key_of(srgb)
      dx = (srgb.width * RollSample::INSET).to_i
      dy = (srgb.height * RollSample::INSET).to_i
      inner = srgb.extract_area(dx, dy, srgb.width - 2 * dx, srgb.height - 2 * dy)
      luma = (inner * ColourBalance::LUMA).bandmean * 3.0
      (Colour.clamp01(luma) * 255).cast(:uchar).percent(50) / 255.0
    end

    # The share of the frame white in every channel, in display values.
    def white_of(srgb)
      low = (srgb[0] < srgb[1]).ifthenelse(srgb[0], srgb[1])
      low = (low < srgb[2]).ifthenelse(low, srgb[2])
      (low > NEAR_WHITE).ifthenelse(1.0, 0.0).avg
    end

    def at_work_size(srgb)
      srgb.width > WORK ? srgb.resize(WORK.to_f / srgb.width) : srgb
    end

    # From nothing at `absent` to all of it at `present`, either way round.
    def ramp(value, absent, present)
      ((value - absent) / (present - absent)).clamp(0.0, 1.0)
    end
  end
end
