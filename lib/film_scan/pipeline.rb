module FilmScan
  # The correction itself, for one frame:
  #
  #   colour balance -> roll fit -> white balance -> vibrance ->
  #   white balance -> endpoints -> tone curve -> contrast -> denoise
  class Pipeline
    LUMA = [0.2126, 0.7152, 0.0722].freeze
    # The second balancing pass is gentle. At full strength it doubles up on
    # the first and pushes corrected bands past neutral.
    SECOND_PASS = 0.35

    # The roll's fits, any of which may be nil: its colour balance and tone
    # curve toward the reference, its gamut fit, the falloff in its corners,
    # and how its frames typically tilt from warm highlights to cool shadows.
    def initialize(options, balance: nil, tone: nil, fit: nil, flat: nil, tilt: nil, reference: nil)
      @o = options
      @balance = balance
      @tone = tone
      @roll = fit
      @flat = flat
      @tilt = tilt
      @reference = reference
    end

    def call(path)
      render(Colour.load(path))
    end

    # How the frame tilts as the frame balance sees it, measured on each of the
    # roll's frames to find what is typical for the roll.
    def tilt(scan)
      WarmLight.tilt(inside(roll_balanced(trim(scan))), @reference.neutral)
    end

    # The frame as the colour shaping receives it: trimmed, then the roll's
    # balance and its own. Nil when the frame balance could not read it, since
    # such a frame is not shaped.
    def balanced(scan)
      scan = roll_balanced(trim(scan))
      return inside(scan) unless frame_balance?

      frame = frame_fit(scan)
      frame && inside(frame.apply(scan))
    end

    # The correction on a loaded frame, a float sRGB image in 0..1.
    def render(scan)
      scan = trim(scan)
      @lost = lost_in(scan)
      return render_monochrome(scan) if @o[:monochrome]

      srgb_in = settled(apply_roll_fit(balance(scan)))

      # Colour is measured and corrected in linear light, where a gain is what
      # it claims to be. Tone work happens later, in display space.
      linear = Colour.to_linear(srgb_in)
      measured = Measurements.new(inside(linear))

      # Balance before vibrance, since the boost would multiply any cast along
      # with the colour, and again after, since it lifts leftover cast hardest.
      linear = apply_tone_gains(linear, measured.tone_gains(@o[:wb], @o[:wb_clamp],
                                                            @o[:shadow_wb]))
      linear = settled(vibrance(linear, vibrance_amount(measured), @o[:knee]))
      after = Measurements.new(inside(linear))
      linear = apply_tone_gains(linear, after.tone_gains(@o[:wb] * SECOND_PASS,
                                                         @o[:wb_clamp], @o[:shadow_wb]))

      srgb = settled(Colour.to_srgb(linear))
      points = Measurements.new(inside(srgb)).endpoints(@o[:black], @o[:white], @o[:neutral],
                                                        max_stretch: @o[:max_stretch])
      srgb = apply_endpoints(srgb, points)
      srgb = @tone.apply(srgb) if @tone
      srgb = settled(s_curve(srgb, contrast_for(points)))
      # Late, on the finished tones, since a sky that is level here is level in
      # the picture: the stretch and the curve both move colour on the way.
      srgb = level_sky(srgb)
      srgb = settled(recover(srgb))
      # Measured once, since the grain tells the denoise how hard to work and
      # the softness tells the sharpening what to do.
      detail = fix?(:sharpen) || fix?(:grain) ? Detail.measure(inside(srgb)) : nil
      srgb = denoise_chroma(srgb, chroma_for(detail), chroma_radius_for(inside(srgb)))
      srgb = fix?(:sharpen) ? Detail.sharpen(srgb, detail, @o[:sharpness]) : srgb
      # Again at the end: the tone curve, the contrast and the recovery all
      # push pixels back over the top after the stretch has fitted them.
      Gamut.fit(srgb, headroom_for(nil))
    end

    private

    # A black and white frame. Labs scan it in colour and leave it tinted, so it
    # is made neutral grey first, then stretched, given contrast, opened at the
    # ends and sharpened as a colour frame would be. It stays three equal bands
    # until it is written.
    def render_monochrome(scan)
      srgb = settled(grey(scan))
      points = Measurements.new(inside(srgb)).endpoints(@o[:black], @o[:white], 0.0, max_stretch: @o[:max_stretch])
      srgb = apply_endpoints(srgb, points)
      srgb = settled(s_curve(srgb, contrast_for(points)))
      srgb = settled(recover(srgb))
      srgb = Detail.sharpen(srgb, Detail.measure(inside(srgb)), @o[:sharpness]) if fix?(:sharpen)
      grey(srgb)
    end

    # Luma in linear light, as three equal sRGB bands.
    def grey(srgb)
      y = Colour.to_srgb((Colour.to_linear(srgb) * LUMA).bandmean * 3.0)
      y.bandjoin([y, y]).copy(interpretation: :srgb)
    end

    # A stage's pixels, worked out and kept.
    #
    # A vips image is a recipe rather than pixels, and every consumer of it runs
    # that recipe again. This pipeline branches at almost every stage, a blur
    # beside the original, a base and its detail, a measurement off an
    # intermediate, so without this the early stages are computed over and over:
    # a 24 megapixel frame took 195 seconds and takes 22 with it.
    def settled(image)
      image.copy_memory
    end

    # Everything that has to happen before the frame is measured: finding where
    # the picture sits, the borders off when --crop asks, and the corners
    # brought back up. The borders are also where this frame's own black floor
    # is read, when the scan has them.
    def trim(scan)
      edges = FrameEdges.detect(scan)
      @floor = edges.floor_offsets if fix?(:floor)
      area = edges.picture
      if area && @o[:crop]
        scan = scan.extract_area(*area)
      else
        @area = area
        @size = [scan.width, scan.height]
      end
      scan = @flat.apply(scan, @area) if @flat && fix?(:flat)
      scan
    end

    # The picture without the borders it was kept with. Overscan and rebate are
    # not part of any scene, so every step reads this and changes the whole
    # frame, and nothing marks where the reading stopped.
    def inside(image)
      @area ? image.extract_area(*@area) : image
    end

    # A mask found on the picture, carried out to the edges of the frame.
    def whole(mask)
      return mask unless @area && mask

      mask.embed(@area[0], @area[1], *@size, extend: :copy)
    end

    def fix?(name)
      @o[:fix]&.include?(name)
    end

    # What the scan bunched at the ends of the range, opened by as much as
    # this frame has to give back. Before the denoise, since lifting a shadow
    # brings its grain up with it.
    def recover(srgb)
      return srgb unless fix?(:shadows)

      picture = inside(srgb)
      measured = Dynamics.measure(picture).dup
      held = 1.0 - Diagnosis.crushed(picture) * (1.0 - CRUSHED_SHADOW_KEEP)
      measured.shadow_room *= held if held < 1.0
      lost = @lost && @lost / 255.0
      # Clipping is read from the scan. By here the correction has carried
      # pale skies near white, and they would count as clipped.
      measured.clipped = inside(lost).avg if lost
      Dynamics.apply(srgb, measured, @o[:recovery], lost: lost)
    end

    # Where the scanner clipped, kept small as eight bits, for the recovery.
    def lost_in(scan)
      return nil unless fix?(:shadows)

      settled((Dynamics.scanner_clipping(scan) * 255.0).cast(:uchar))
    end

    # How much of the shadow lift a frame with a crushed channel keeps. The
    # lift brightens what the other two channels hold and cannot bring the
    # crushed one back, so on Phoenix it only makes the shadows more teal.
    CRUSHED_SHADOW_KEEP = 0.35

    # A frame that needed the whole stretch it was allowed is flat by nature,
    # fog or an overcast sky, and contrast on top of the stretch mostly
    # multiplies grain. It keeps this much of the profile's contrast.
    STRETCHED_CONTRAST_KEEP = 0.5

    def contrast_for(points)
      spans = points.map { |lo, hi| hi - lo }
      stretch = 1.0 / [spans.sum / spans.size, 1e-6].max
      capped = @o[:max_stretch] && stretch >= @o[:max_stretch] * 0.95
      capped ? @o[:contrast] * STRETCHED_CONTRAST_KEEP : @o[:contrast]
    end

    # The roll's colour balance, then this frame's own, which takes out how far
    # the lab's balance drifted on this frame in particular.
    def balance(scan)
      scan = roll_balanced(scan)
      # A roll steady enough to need no frame balance still has the film's own
      # colour to reshape, so the shaping runs without one.
      return shape(scan) unless frame_balance?

      # Settled, since the frame fit, the lamp check and the correction each
      # read it through.
      scan = settled(scan)
      frame = frame_fit(scan)
      # A frame the fit could not read is not one to infer lost colour on
      # either: the shaping assumes a frame balanced to the reference, and on a
      # dark interior it reads backlit amber glass as stone with no blue left.
      return scan unless frame

      # Without headroom: the frame's correction is small, and darkening a near
      # white pixel to fit it turned an overcast sky into a grey-lilac slab.
      shape(frame.apply(scan))
    end

    def frame_balance?
      @reference && @o[:frame_balance].positive?
    end

    def frame_fit(scan)
      picture = inside(scan)
      frame = ColourBalance.fit_frame(picture, @reference.neutral, limit: @o[:frame_balance_limit],
                                                                   skip: sky_in(picture))
      return nil unless frame

      frame = keep_warmth(frame, picture)
      limit = @o[:frame_tint_limit]
      frame = WarmLight.cap_tint(frame, limit / @o[:frame_balance]) if limit
      frame.strength = @o[:frame_balance]
      frame
    end

    def roll_balanced(scan)
      roll = @balance && (@floor ? @balance.with_offsets(@floor) : @balance)
      roll ? with_headroom(roll, scan).apply(scan) : scan
    end

    # Warm light the frame balance should leave alone: lamps it finds itself,
    # and whatever share a frame's own settings ask it to keep, which is the
    # only way sunlit golden hour survives.
    def keep_warmth(frame, scan)
      held = @o[:keep_warmth].to_f
      guard = @o[:lamp_guard].to_f
      held = [held, guard * WarmLight.confidence(scan, @reference.neutral, @tilt)].max if guard.positive? && @tilt
      held.positive? ? WarmLight.hold(frame, held.clamp(0.0, 1.0)) : frame
    end

    # A sky may be any blue it likes and may be grey, and may not come out
    # warm, which is the one thing measurement supports saying about it.
    def level_sky(srgb)
      room = @o[:sky_floor].to_f
      return srgb unless room.positive?

      picture = inside(srgb)
      mask = Sky.mask(picture)
      levelled = Sky.level(srgb, whole(mask), room, Sky.floor_gains(picture, mask, room))
      # Settled when it moved anything, since the recovery reads it several times.
      levelled.equal?(srgb) ? srgb : settled(levelled)
    end

    # A sky is a large smooth surface sitting near neutral, which is exactly
    # what the drift fit goes looking for, so it takes the fit over and the
    # rest of the frame is balanced to suit it. Kept out of the estimate when
    # the profile asks and the detector is willing to name one.
    def sky_in(scan)
      return nil unless @o[:sky_neutral]

      Sky.mask(scan)
    end

    # A gain that would take a pixel past white darkens it instead, by up to
    # the profile's headroom, so the colour the gain asked for survives.
    def with_headroom(fit, scan)
      fit.headroom = headroom_for(scan)
      fit
    end

    # A frame with a sky in it gets the sky's headroom when that is the larger,
    # since the sky is where a channel runs into white and takes the sky's
    # colour with it. Found once per frame, on the scan as it arrives.
    def headroom_for(scan)
      room = @o[:highlight_headroom].to_f
      sky_room = @o[:sky_headroom].to_f
      return room unless sky_room > room

      @sky_found = !Sky.mask(inside(scan)).nil? if @sky_found.nil? && scan
      @sky_found ? sky_room : room
    end

    # Two ways past what per-channel gains can reach, both off unless a
    # profile or the command line asks: easing toward grey where a channel has
    # nothing left, and bending the film's colour onto the reference's shape.
    def shape(scan)
      wants_map = @reference && @o[:chroma_shape].to_f.positive? && @o[:chroma_map]
      wants_easing = @reference && @o[:lost_colour].to_f.positive?
      return scan unless wants_map || wants_easing

      linear = Colour.to_linear(scan)
      lost = LostColour.lost(linear, (linear * LUMA).bandmean * 3.0, @reference.neutral)
      if wants_map
        map = ChromaMap.from_cache(@o[:chroma_map].transform_keys(&:to_sym))
        map.strength = @o[:chroma_shape]
        scan = map.apply(scan, lost, linear: linear)
      end
      wants_easing ? LostColour.apply(scan, @reference.neutral, @o[:lost_colour]) : scan
    end

    # The roll's colour fit: a per-channel gain that varies with brightness.
    # Indexed on blurred luminance, so neighbouring grains get the same gain
    # and luminance noise is not turned into colour noise.
    def apply_roll_fit(srgb)
      return srgb unless @roll

      guide = (srgb * LUMA).bandmean * 3.0
      index = (Colour.clamp01(guide).gaussblur(2.0) * 255.0).cast(:uchar)
      curves = @roll.vips_curves
      bands = (0..2).map { |c| srgb[c] * index.maplut(curves[c]) }
      Colour.clamp01(rejoin(bands))
    end

    # Rebuilding an image band by band loses the sRGB tag, and vips then saves
    # it as greyscale. Put the tag back.
    def rejoin(bands)
      bands[0].bandjoin([bands[1], bands[2]]).copy(interpretation: :srgb)
    end

    # Either a fixed boost, or solved per frame for the target saturation.
    def vibrance_amount(measured)
      return @o[:saturation] if @o[:saturation]
      measured.vibrance_for(@o[:target_saturation], @o[:knee], @o[:max_vibrance])
    end

    # Per-anchor gains applied as a curve indexed by brightness, so shadows and
    # highlights cast in different directions can both be corrected.
    def apply_tone_gains(image, gains)
      return image unless gains
      y = luma_of(image)

      # Blurred for the same reason as the roll fit, and indexed in sRGB to
      # match how build_curve fills each entry.
      guide = y.gaussblur(2.0)
      index = (Colour.to_srgb(guide) * 255.0).cast(:uchar)
      bands = (0..2).map do |c|
        lut = Vips::Image.new_from_array([build_curve(gains, c)])
        image[c] * index.maplut(lut)
      end
      rejoin(bands)
    end

    # Expand the anchor gains into one entry per luma value, interpolating in
    # the linear light the anchors were measured in.
    def build_curve(gains, channel)
      anchors = Measurements::TONE_ANCHORS
      (0..255).map do |i|
        y = Colour.srgb_to_linear_scalar(i / 255.0)
        if y <= anchors.first
          gains.first[channel]
        elsif y >= anchors.last
          gains.last[channel]
        else
          hi = anchors.index { |a| a >= y }
          lo = hi - 1
          span = anchors[hi] - anchors[lo]
          t = span.zero? ? 0.0 : (y - anchors[lo]) / span
          gains[lo][channel] * (1 - t) + gains[hi][channel] * t
        end
      end
    end

    # Vibrance rather than flat saturation: strongest near grey and halving at
    # the knee, so washed-out colours recover and strong ones are left alone.
    def vibrance(image, amount, knee)
      return image if amount == 1.0
      y = luma_of(image)
      r, g, b = image[0], image[1], image[2]
      mx = (r > g).ifthenelse(r, g)
      mx = (mx > b).ifthenelse(mx, b)
      mn = (r < g).ifthenelse(r, g)
      mn = (mn < b).ifthenelse(mn, b)
      safe_y = (y < 1e-6).ifthenelse(1e-6, y)
      ratio = ((mx - mn) / safe_y) / knee
      k = (ratio * ratio + 1.0)**-1.0 * (amount - 1.0) + 1.0
      (image - y) * k + y
    end

    # The stretch clips as surely as a gain does, and on a near white sky it is
    # the channel that was already highest that goes first, which leaves the
    # sky reading as that channel's colour. Given headroom, such a pixel is
    # darkened instead.
    def apply_endpoints(image, points)
      lo = points.map(&:first)
      span = points.map { |p| [p[1] - p[0], 1e-6].max }
      Gamut.fit((image - lo) / span, headroom_for(nil))
    end

    # Contrast around mid grey. The minus matters: sin is positive below mid
    # grey, so adding it would lift the shadows instead.
    def s_curve(image, amount)
      return image if amount <= 0
      k = amount / (2.0 * Math::PI)
      # vips sin() takes degrees, so scale the turn to 360 rather than 2*pi.
      Colour.clamp01(image - (image * 360.0).sin * k)
    end

    # Blur the colour difference from luma and leave luma alone, so grain and
    # detail survive while colour speckle goes. A second, wider pass catches
    # the larger colour blotches the fine speckle sits on.
    def denoise_chroma(image, amount, radius)
      return image if amount <= 0
      y = luma_of(image)
      diff = image - y
      fine = diff.gaussblur(sigma_for(radius))
      coarse = fine.gaussblur(sigma_for(radius * 3))
      d = diff * (1.0 - amount) + fine * amount
      d = d * (1.0 - amount * 0.55) + coarse * (amount * 0.55)
      Colour.clamp01(d + y)
    end

    # The grain a well-scanned frame carries, which the profile's chroma
    # setting is written against.
    USUAL_GRAIN = 0.008

    # How hard to clean the colour speckle. The profile says what this film
    # usually needs, and the grain measured on this frame moves it, so the
    # grainy frames of a roll are cleaned harder than the smooth ones.
    def chroma_for(detail)
      return @o[:chroma] unless detail && fix?(:grain)

      (@o[:chroma] * detail.grain / USUAL_GRAIN).clamp(0.0, 0.95)
    end

    # Grain covers fewer pixels in a smaller scan, so the radius scales with
    # width: 5px at 6144 wide.
    def chroma_radius_for(image)
      return @o[:chroma_radius] if @o[:chroma_radius]
      [(5.0 * image.width / 6144.0).round, 2].max
    end

    # A gaussian matched in variance to a box blur of this radius.
    def sigma_for(radius)
      (2 * radius + 1) / Math.sqrt(12)
    end

    def luma_of(image)
      (image * LUMA).bandmean * 3.0
    end
  end
end
