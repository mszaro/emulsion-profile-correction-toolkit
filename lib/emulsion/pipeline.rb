module Emulsion
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
    # curve toward the reference, and its gamut fit.
    def initialize(options, balance: nil, tone: nil, fit: nil, reference: nil)
      @o = options
      @balance = balance
      @tone = tone
      @roll = fit
      @reference = reference
    end

    def call(path)
      render(Colour.load(path))
    end

    # The correction on a loaded frame, a float sRGB image in 0..1.
    def render(scan)
      srgb_in = apply_roll_fit(balance(scan))

      # Colour is measured and corrected in linear light, where a gain is what
      # it claims to be. Tone work happens later, in display space.
      linear = Colour.to_linear(srgb_in)
      measured = Measurements.new(linear)

      # Balance before vibrance, since the boost would multiply any cast along
      # with the colour, and again after, since it lifts leftover cast hardest.
      linear = apply_tone_gains(linear, measured.tone_gains(@o[:wb], @o[:wb_clamp],
                                                            @o[:shadow_wb]))
      linear = vibrance(linear, vibrance_amount(measured), @o[:knee])
      after = Measurements.new(linear)
      linear = apply_tone_gains(linear, after.tone_gains(@o[:wb] * SECOND_PASS,
                                                         @o[:wb_clamp], @o[:shadow_wb]))

      srgb = Colour.to_srgb(linear)
      points = Measurements.new(srgb).endpoints(@o[:black], @o[:white], @o[:neutral],
                                                max_stretch: @o[:max_stretch])
      srgb = apply_endpoints(srgb, points)
      srgb = @tone.apply(srgb) if @tone
      srgb = s_curve(srgb, @o[:contrast])
      denoise_chroma(srgb, @o[:chroma], chroma_radius_for(srgb))
    end

    private

    # The roll's colour balance, then this frame's own, which takes out how far
    # the lab's balance drifted on this frame in particular.
    def balance(scan)
      scan = @balance.apply(scan) if @balance
      return scan unless @reference && @o[:frame_balance].positive?

      frame = ColourBalance.fit_frame(scan, @reference.neutral, limit: @o[:frame_balance_limit])
      return scan unless frame

      frame.strength = @o[:frame_balance]
      frame.apply(scan)
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

    def apply_endpoints(image, points)
      lo = points.map(&:first)
      span = points.map { |p| [p[1] - p[0], 1e-6].max }
      Colour.clamp01((image - lo) / span)
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
