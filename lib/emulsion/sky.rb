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
    TOP_COVER = 0.25

    # The least of the frame worth excluding, and the most colour variation a
    # sky may hold. A lit vault or a ceiling passes everything above and fails
    # this: a real sky is even, a room is not.
    MIN_SHARE = 0.04

    # How far under each line a pixel still counts for something.
    SOFT_LUMA = 0.10
    SOFT_REACH = 0.12
    MAX_VARIATION = 0.18

    # How far the edge of the correction is blurred, as a share of the width.
    FEATHER = 0.01

    # Half the scans carry an orientation tag, and up is the whole point here,
    # so the frame is stood upright to be read and the mask is turned back to
    # match the pixels the caller holds. A tag that flips rather than turns is
    # rare enough to decline.
    TURNS = { 1 => nil, 3 => "d180", 6 => "d270", 8 => "d90" }.freeze

    def mask(srgb)
      orientation = srgb.get_typeof("orientation").zero? ? 1 : srgb.get("orientation")
      return nil unless TURNS.key?(orientation)

      found = upright_mask(srgb.autorot)
      return nil unless found

      back = TURNS[orientation]
      back ? found.rot(back) : found
    end

    # The one thing a sky may be told about its colour.
    #
    # Measured across 14 Superia daylight frames, deep blue through overcast,
    # a sky's blue against green runs from +0.04 to +1.74 stops and is never
    # negative, and its red against green never passes +0.02. So a floor is
    # defensible where a target would not be: a sky may be any blue it likes,
    # and may be grey, and may not come out warm. Golden hour is safe, because
    # the light lands on what the sky is over rather than on the sky.
    #
    # The correction is local to the mask, feathered at its edge, and capped,
    # so a frame where the detector is wrong loses very little.
    def level(srgb, mask, limit)
      return srgb if mask.nil? || limit <= 0

      share = mask.avg
      return srgb if share <= 0

      linear = Colour.to_linear(srgb)
      stops = (0..2).map { |c| (linear[c] * mask).avg / share }
      blue = Math.log2(stops[2] / stops[1])
      red = Math.log2(stops[0] / stops[1])
      lift = [[-blue, 0.0].max, limit].min
      cut = [[red, 0.0].max, limit].min
      return srgb if lift.zero? && cut.zero?

      feather = mask.gaussblur([srgb.width * FEATHER, 1.0].max)
      gains = [2**-cut, 1.0, 2**lift]
      moved = (0..2).map { |c| linear[c] * (feather * (gains[c] - 1.0) + 1.0) }
      Colour.to_srgb(Colour.clamp01(moved[0].bandjoin([moved[1], moved[2]]))).copy(interpretation: :srgb)
    end

    # Read at one size whatever the frame's own. Texture is what separates a
    # sky from a wall of brickwork, and at full resolution the grain of the
    # film is texture too, so the same frame would answer differently at every
    # scale. Small enough that grain averages away, large enough that a roof
    # line does not.
    WORK = 900

    # Returns a 0 or 1 mask of the sky, or nil when the frame does not hold one
    # the detector is willing to name. `srgb` is float sRGB in 0..1, upright.
    def upright_mask(frame)
      scale = WORK.to_f / frame.width
      srgb = scale < 1.0 ? frame.resize(scale) : frame
      found = found_in(srgb)
      return nil unless found
      return found if srgb.width == frame.width

      grown = found.resize(frame.width.to_f / srgb.width)
      grown.embed(0, 0, frame.width, frame.height, extend: :copy)
    end

    # How much of each pixel is sky, from 0 to 1, and how sure the frame is that
    # it holds one at all. A verdict threw away every frame that sat near a
    # line, which turned out to be most of the frames whose skies were wrong:
    # the floor never ran on them.
    def found_in(srgb)
      luma = (srgb * LUMA).bandmean * 3.0
      weight = bright(luma) * flat(luma, srgb) * high(srgb)
      weight = settle(weight, srgb)
      share = weight.avg
      return nil if share < MIN_SHARE / 2.0

      sure = confidence(weight, srgb, share)
      return nil if sure <= 0.05

      weight * sure
    end

    # How much the frame is believed, from how much of it the sky covers, how
    # much of the top edge it reaches, and how evenly its colour holds together.
    def confidence(weight, srgb, share)
      band = weight.extract_area(0, 0, srgb.width, [(srgb.height * TOP_BAND).to_i, 1].max)
      ramp(share, MIN_SHARE / 2.0, MIN_SHARE * 1.5) *
        ramp(band.avg, TOP_COVER / 2.0, TOP_COVER) *
        ramp(variation(srgb, weight, share), MAX_VARIATION * 1.6, MAX_VARIATION * 0.7)
    end

    # From nothing at `absent` to all of it at `present`, either way round.
    def ramp(value, absent, present)
      ((value - absent) / (present - absent)).clamp(0.0, 1.0)
    end

    # Brightness is read in display space, where the percentile and the floor
    # both mean what they look like. A pixel a little under the line counts for
    # part of one rather than for nothing.
    def bright(luma)
      cut = [(luma * 255.0).cast(:uchar).percent(BRIGHT_PERCENTILE) / 255.0, BRIGHT_FLOOR].max
      # The floor stays hard, since nothing under it is a daylight sky, and
      # only the frame's own percentile is softened.
      soft(luma, cut - SOFT_LUMA, cut) * (luma > BRIGHT_FLOOR).ifthenelse(1.0, 0.0)
    end

    # Flat for its size: local detail against a blur of the same radius.
    def flat(luma, srgb)
      radius = [srgb.width * BLUR, 1.0].max
      detail = (luma - luma.gaussblur(radius)).abs.gaussblur(radius)
      soft(detail, TEXTURE * 2.0, TEXTURE)
    end

    def high(srgb)
      rows = Vips::Image.xyz(srgb.width, srgb.height)[1] / srgb.height.to_f
      soft(rows, REACH + SOFT_REACH, REACH)
    end

    # Speckle is not sky. A blur keeps the regions that have neighbours and
    # fades the pixels that do not.
    def settle(weight, srgb)
      weight.gaussblur([srgb.width * BLUR * 2, 1.0].max)
    end

    # A smooth step from 0 at `absent` to 1 at `present`, either way round.
    def soft(image, absent, present)
      t = ((image - absent) / (present - absent))
      t = (t < 0).ifthenelse(0, (t > 1).ifthenelse(1, t))
      t * t * (t * -2.0 + 3.0)
    end

    def reaches_the_top?(candidate, srgb)
      band = candidate.extract_area(0, 0, srgb.width, [(srgb.height * TOP_BAND).to_i, 1].max)
      band.avg >= TOP_COVER
    end

    # How much the colour wanders inside the region, in stops of blue against
    # green. Even a hazy sky holds together; a room full of lamps does not.
    def variation(srgb, candidate, share)
      linear = Colour.to_linear(srgb)
      green = (linear[1] < 1e-5).ifthenelse(1e-5, linear[1])
      blue = (linear[2] < 1e-5).ifthenelse(1e-5, linear[2])
      stops = (blue / green).log / Math.log(2)
      weight = candidate
      mean = (stops * weight).avg / share
      square = (stops * stops * weight).avg / share
      Math.sqrt([square - mean * mean, 0.0].max)
    end
  end
end
