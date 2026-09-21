module Emulsion
  # Where the sky is, so that the neutral estimate can stop treating it as a
  # grey card.
  #
  # The frame's colour drift is fitted on whatever the estimator decides is
  # neutral, and a pale sky is a large, smooth, bright surface sitting close to
  # neutral already: on the Phoenix rolls it takes over the brightest tone band
  # on exactly the frames whose skies come out wrong, and the fit then drives
  # it onto the reference's grey while the buildings in the same frame drift
  # the other way.
  #
  # Nothing here looks at colour. A detector keyed on colour could never see a
  # sky that has gone yellow, which is the case this exists for. It is geometry
  # and smoothness: bright for the frame, flat, high up, and reaching the top
  # edge.
  module Sky
    module_function

    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Brightness to qualify, as a percentile of the frame and as a floor, so a
    # frame of dark interiors cannot nominate its brightest corner.
    BRIGHT_PERCENTILE = 70
    BRIGHT_FLOOR = 0.42

    # How flat a surface has to be. Measured as local detail against a blur, at
    # a radius that scales with the frame.
    TEXTURE = 0.012
    BLUR = 0.004

    # How far down the frame a sky may reach, and how much of the top edge it
    # has to cover before it is believed.
    REACH = 0.62
    TOP_BAND = 0.06
    TOP_COVER = 0.35

    # The least of the frame worth excluding, and the most colour variation a
    # sky may hold. A lit vault or a ceiling passes everything above and fails
    # this: a real sky is even, a room is not.
    MIN_SHARE = 0.04
    MAX_VARIATION = 0.18

    # Returns a 0 or 1 mask of the sky, or nil when the frame does not hold one
    # the detector is willing to name. `srgb` is float sRGB in 0..1.
    def mask(srgb)
      luma = (srgb * LUMA).bandmean * 3.0
      candidate = bright(luma) & flat(luma, srgb) & high(srgb)
      candidate = settle(candidate, srgb)
      share = candidate.avg / 255.0
      return nil if share < MIN_SHARE
      return nil unless reaches_the_top?(candidate, srgb)
      return nil if variation(srgb, candidate, share) > MAX_VARIATION

      candidate / 255.0
    end

    # Brightness is read in display space, where the percentile and the floor
    # both mean what they look like.
    def bright(luma)
      cut = [(luma * 255.0).cast(:uchar).percent(BRIGHT_PERCENTILE) / 255.0, BRIGHT_FLOOR].max
      luma > cut
    end

    # Flat for its size: local detail against a blur of the same radius.
    def flat(luma, srgb)
      radius = [srgb.width * BLUR, 1.0].max
      (luma - luma.gaussblur(radius)).abs.gaussblur(radius) < TEXTURE
    end

    def high(srgb)
      Vips::Image.xyz(srgb.width, srgb.height)[1] < srgb.height * REACH
    end

    # Speckle is not sky. A blur and a threshold keep the regions that have
    # neighbours and drop the pixels that do not.
    def settle(candidate, srgb)
      (candidate.gaussblur([srgb.width * BLUR * 2, 1.0].max) > 140)
    end

    def reaches_the_top?(candidate, srgb)
      band = candidate.extract_area(0, 0, srgb.width, [(srgb.height * TOP_BAND).to_i, 1].max)
      band.avg / 255.0 >= TOP_COVER
    end

    # How much the colour wanders inside the region, in stops of blue against
    # green. Even a hazy sky holds together; a room full of lamps does not.
    def variation(srgb, candidate, share)
      linear = Colour.to_linear(srgb)
      green = (linear[1] < 1e-5).ifthenelse(1e-5, linear[1])
      blue = (linear[2] < 1e-5).ifthenelse(1e-5, linear[2])
      stops = (blue / green).log / Math.log(2)
      weight = candidate / 255.0
      mean = (stops * weight).avg / share
      square = (stops * stops * weight).avg / share
      Math.sqrt([square - mean * mean, 0.0].max)
    end
  end
end
