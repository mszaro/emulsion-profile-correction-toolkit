module Emulsion
  # Opens crushed shadows and pulls back held highlights, one frame at a time.
  #
  # Stretching a frame's black and white points decides where its ends land but
  # not how much of the subject fits between them, so a church interior still
  # arrives with a black nave and blown windows. This splits the frame into a
  # large-scale base and the detail riding on it, bends the base alone and puts
  # the detail back untouched, which opens the shadows without flattening them.
  # Channels clipped at white are estimated back from the ones that survived,
  # since a pixel missing a channel comes back the wrong colour and not merely
  # the wrong brightness.
  #
  # Every radius here is a fraction of the frame, so a measurement taken on a
  # thumbnail describes the full-size frame just as well.
  module Dynamics
    module_function

    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Scans carry a bright scanner border, which would read as blown highlight,
    # so measuring stays inside the same inset the frame measurements use.
    INSET = 0.05

    # Long edge the frame is shrunk to before it is measured. Shadow and
    # highlight are properties of regions rather than of single grains.
    MEASURE_EDGE = 640

    # Where shadow and highlight begin, and where a channel counts as clipped.
    # Under SHADOW_FLOOR nothing survives that lifting could bring back.
    SHADOW_FLOOR = 0.012
    SHADOW_EDGE = 0.18
    HIGHLIGHT_EDGE = 0.80
    CLIP = 0.97

    # The share of a frame in shadow, or in held highlight, that counts as none
    # of it and as all of it.
    SHADOW_SPAN = [0.06, 0.40].freeze
    HIGHLIGHT_SPAN = [0.03, 0.28].freeze

    # Opening one end of a frame matters most when there is something at the
    # other end. A frame with nothing bright in it is dark because it was dark,
    # so it is held back rather than passed over.
    OPPOSITE_SPAN = [0.02, 0.18].freeze
    OPPOSITE_FLOOR = 0.6

    # The most the measurement may ask for, as the exponents of the two gamma
    # bends the base curve is built from.
    SHADOW_PUSH = 0.85
    HIGHLIGHT_PULL = 0.55

    # How fast each bend gives out toward the far end of the range, so lifting
    # the shadows does not also wash the midtones.
    MASK = 2.0

    # The most the base may be multiplied by. Deep shadow is mostly grain, and
    # grain magnified is what a lifted frame looks wrong for.
    MAX_GAIN = 2.6

    # Where a lift starts being held back, since a pixel already near white has
    # nowhere to go and would only clip.
    HOLD_EDGE = 0.75

    LUT_SIZE = 1024

    # The base layer: how wide it looks, how far the guided filter lets an edge
    # through, and the small copy its coefficients are solved on.
    BASE_RADIUS = 0.08
    BASE_EPS = 0.01
    BASE_EDGE = 400

    # Gaussians here are wide, and the default truncation leaves a visible step
    # at the end of the mask when the result is used as a base layer.
    BLUR_AMPL = 0.02

    # Where a channel starts counting as clipped and where it is fully gone.
    # The estimate fades in across the pair, so there is no seam at either.
    CLIP_LOW = 0.90
    CLIP_HIGH = 0.995

    # Too little clipping to be worth reconstructing.
    MIN_CLIPPED = 0.0005

    # The neighbourhood a clipped pixel borrows its colour from, how far the
    # count leans toward the neighbours nearest to clipping themselves, and how
    # much of the frame's own average stands behind the lot.
    NEIGHBOUR_EDGE = 320
    NEIGHBOUR_RADIUS = 0.06
    BRIGHT_BIAS = 8.0
    FALLBACK = 0.05

    # How far a reconstructed pixel is brought back into range, and the most
    # overshoot that counts. Full recovery gives the exact colour at the cost
    # of a grey patch where the sky was.
    RECOVER = 0.75
    OVERSHOOT_MAX = 1.6

    TINY = 1e-6

    # What one frame has to spare at each end, and how much of it is already
    # gone. All three are shares of the frame, 0 to 1.
    Measurement = Struct.new(:shadow_room, :highlight_room, :clipped) do
      # A frame that already fits the range it was given.
      def quiet?
        shadow_room < 0.02 && highlight_room < 0.02 && clipped < MIN_CLIPPED
      end

      def to_h
        { "shadow_room" => shadow_room, "highlight_room" => highlight_room,
          "clipped" => clipped }
      end

      def report
        format("  dynamics   shadows %.2f   highlights %.2f   clipped %.3f",
               shadow_room, highlight_room, clipped)
      end
    end

    # Expects a float sRGB image in 0..1, which is what the whole pipeline uses.
    def measure(image)
      frame = inset(image)
      small = shrink_to(frame, MEASURE_EDGE)
      y = luma(small)
      top = peak(bands_of(small))

      # Shadow that still holds something, and highlight that is dim enough to
      # still hold something. Either one past its threshold is already gone.
      shadow = share((y > SHADOW_FLOOR) & (y < SHADOW_EDGE))
      highlight = share((y > HIGHLIGHT_EDGE) & (top < CLIP))
      clipped = share(peak(bands_of(frame)) >= CLIP)

      Measurement.new(
        (ramp(shadow, SHADOW_SPAN) * opposite(highlight + clipped)).round(4),
        (ramp(highlight, HIGHLIGHT_SPAN) * opposite(shadow)).round(4),
        clipped.round(4)
      )
    end

    # A corrected copy, at `amount` of full strength. A frame with nothing to
    # recover, and any frame at all at zero strength, comes back as it went in.
    def apply(image, measurement, amount)
      return image if measurement.nil? || amount <= 0 || measurement.quiet?

      out = reconstruct(image, measurement, amount)
      tone_map(out, measurement, amount).copy(interpretation: :srgb)
    end

    # How much of the frame sits between the ends of a span.
    def ramp(value, span)
      ((value - span[0]) / (span[1] - span[0])).clamp(0.0, 1.0)
    end

    def opposite(share)
      OPPOSITE_FLOOR + (1.0 - OPPOSITE_FLOOR) * ramp(share, OPPOSITE_SPAN)
    end

    # Local tone mapping. The base carries the frame's large shapes and takes
    # the whole bend; the detail rides on top of it as a ratio, so lifted
    # shadows keep their contrast instead of going flat grey. Brightness moves
    # and the colour ratios stay, since bending each channel on its own would
    # multiply whatever tint the frame still has.
    def tone_map(image, measurement, amount)
      lift = SHADOW_PUSH * amount * measurement.shadow_room
      pull = HIGHLIGHT_PULL * amount * measurement.highlight_room
      return image if lift < 1e-3 && pull < 1e-3

      y = luma(image)
      base = guided_base(y, BASE_RADIUS * long_edge(image), BASE_EPS)
      gain = lut_of(base, gains(lift, pull))
      Colour.clamp01(image * held_back(gain, y))
    end

    # A lift is eased off as the pixel approaches white. A pull back is not,
    # since that is the end being rescued.
    def held_back(gain, y)
      hold = smoothstep(y, HOLD_EDGE, 1.0)
      (gain > 1.0).ifthenelse((gain - 1.0) * hold.linear(-1, 1) + 1.0, gain)
    end

    # The base curve, kept as the gain per level rather than the level itself,
    # so one multiply moves the whole pixel and its colour ratios survive.
    def gains(lift, pull)
      (0...LUT_SIZE).map do |i|
        x = i / (LUT_SIZE - 1).to_f
        next MAX_GAIN if x < TINY

        [curve_at(x, lift, pull) / x, MAX_GAIN].min
      end
    end

    # Two gamma bends, each masked to its own end of the range: one opens the
    # bottom, the other brings the top down. Both hold 0 at 0 and 1 at 1.
    def curve_at(x, lift, pull)
      y = x
      y += ((x**(1.0 / (1.0 + lift))) - x) * (1.0 - x)**MASK if lift.positive?
      y += ((1.0 - (1.0 - y)**(1.0 / (1.0 + pull))) - y) * x**MASK if pull.positive?
      y
    end

    # An edge-aware base rather than a plain blur, which would bleed the sky
    # across a roof line and leave a halo along it once the base is bent.
    # Inside an even area the window's variance is small and the pixel comes
    # back as its average; across an edge the variance is large and the pixel
    # comes back as itself, so nothing is carried over the edge.
    #
    # The window coefficients vary slowly, so they are solved on a small copy
    # and stretched back over the full frame, which is what keeps a 6144px
    # frame affordable at this radius.
    def guided_base(y, radius, eps)
      small = shrink_to(y, BASE_EDGE)
      sigma = [radius * small.width / y.width.to_f, 1.0].max
      mean = blur(small, sigma)
      var = blur(small * small, sigma) - mean * mean
      var = (var < 0).ifthenelse(0, var)

      a = var / (var + eps)
      b = mean * a.linear(-1, 1)
      resize_to(blur(a, sigma), y) * y + resize_to(blur(b, sigma), y)
    end

    # Highlight reconstruction. A channel clipped at white has lost whatever it
    # held above there, and with it the pixel's colour: a sky that clipped red
    # comes back cyan. What the channel held is estimated from the ones that
    # survived, in the proportions its unclipped neighbours have, and faded in
    # across the clipping threshold so nothing marks where it starts. Pixels
    # with all three channels gone are left white.
    def reconstruct(image, measurement, amount)
      return image if measurement.clipped < MIN_CLIPPED

      here = bands_of(image)
      near = bands_of(neighbour_colour(image))
      clip = here.map { |c| smoothstep(c, CLIP_LOW, CLIP_HIGH) * amount }
      keep = clip.map { |c| c.linear(-1, 1) }

      # How far the surviving channels sit above the colour the neighbours
      # have. Both sums fade away together once every channel has gone, which
      # leaves the scale at one and a blown pixel as white as it arrived.
      scale = (sum_of(here.zip(keep)) + TINY) / (sum_of(near.zip(keep)) + TINY)

      bands = here.zip(near, clip).map do |c, colour, gone|
        estimate = colour * scale
        # Never under what was recorded: the channel clipped, so it held at
        # least this much.
        estimate = (estimate > c).ifthenelse(estimate, c)
        c + (estimate - c) * gone
      end
      rolled(bands)
    end

    # The colour the unclipped pixels around here have, leaning hard on the
    # ones nearest to clipping since those are the ones a clipped pixel was on
    # its way to becoming. A blown region can be wider than the neighbourhood,
    # so the frame's own average stands behind it and takes over where no
    # neighbour is left.
    def neighbour_colour(image)
      small = shrink_to(image, NEIGHBOUR_EDGE)
      top = peak(bands_of(small))
      open = smoothstep(top, CLIP_LOW, CLIP_HIGH)
      weight = open.linear(-1, 1) * top**BRIGHT_BIAS

      sigma = NEIGHBOUR_RADIUS * long_edge(small)
      total = [weight.avg, TINY].max
      mean = bands_of(small).map { |c| (c * weight).avg / total }
      floor = [total * FALLBACK, TINY].max

      local = blur(small * weight, sigma) + mean.map { |m| m * floor }
      resize_to(local / (blur(weight, sigma) + floor), image)
    end

    # An estimate can land above white, where no screen goes. Bringing the
    # whole pixel down together keeps its colour, and bringing it down all the
    # way would leave a grey patch where the sky was, so it comes part of the
    # way and the rest clips as it did before.
    def rolled(bands)
      top = peak(bands)
      over = (top < 1.0).ifthenelse(1.0, top)
      over = (over > OVERSHOOT_MAX).ifthenelse(OVERSHOOT_MAX, over)
      scale = over**RECOVER
      Colour.clamp01(join(bands.map { |c| c / scale }))
    end

    # The curve read off its table, interpolated between the entries so a wide
    # flat area does not band.
    def lut_of(image, values)
      table = Vips::Image.new_from_array([values])
      scaled = Colour.clamp01(image) * (LUT_SIZE - 1)
      lo = scaled.floor
      frac = scaled - lo
      lo = lo.cast(:ushort)
      hi = (lo + 1).cast(:ushort)
      lo.maplut(table) + (hi.maplut(table) - lo.maplut(table)) * frac
    end

    def smoothstep(image, lo, hi)
      t = Colour.clamp01((image - lo) / (hi - lo))
      t * t * (t * -2.0 + 3.0)
    end

    def blur(image, sigma)
      image.gaussblur(sigma, min_ampl: BLUR_AMPL)
    end

    def bands_of(image)
      (0..2).map { |c| image[c] }
    end

    # Each band against its weight, added up.
    def sum_of(pairs)
      pairs.map { |band, weight| band * weight }.reduce(:+)
    end

    def peak(bands)
      bands.reduce { |a, b| (a > b).ifthenelse(a, b) }
    end

    # Rebuilding an image band by band loses the sRGB tag, and vips then saves
    # it as greyscale. Put the tag back.
    def join(bands)
      bands[0].bandjoin(bands[1..]).copy(interpretation: :srgb)
    end

    def luma(image)
      (image * LUMA).bandmean * 3.0
    end

    def long_edge(image)
      [image.width, image.height].max
    end

    # A share of the frame, from a mask vips fills with 255 where it holds.
    def share(mask)
      mask.avg / 255.0
    end

    def inset(image)
      dx = (image.width * INSET).to_i
      dy = (image.height * INSET).to_i
      return image if dx.zero? || dy.zero?

      image.extract_area(dx, dy, image.width - 2 * dx, image.height - 2 * dy)
    end

    # Held in memory, since several blurs read the same small copy and
    # shrinking a 6144px frame again for each of them is the expensive part.
    def shrink_to(image, edge)
      long = long_edge(image)
      return image if long <= edge

      image.resize(edge.to_f / long).copy_memory
    end

    def resize_to(image, target)
      return image if image.width == target.width && image.height == target.height

      image.resize(target.width / image.width.to_f,
                   vscale: target.height / image.height.to_f, kernel: :cubic)
    end
  end
end
