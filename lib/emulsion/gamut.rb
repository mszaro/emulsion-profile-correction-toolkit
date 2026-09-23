module Emulsion
  # Bringing a pixel back inside the range without throwing its colour away.
  #
  # Clipping takes each channel down to white on its own, so a pixel that was
  # over the top comes back a different colour: the channels that fit keep
  # their level, the ones that do not all arrive at the same one, and hue and
  # saturation go together. A quarter of a frame can pass through the endpoint
  # stretch that way, which is what a washed out highlight is.
  #
  # Two things are spent instead, in order. Brightness first, since a pixel
  # scaled down keeps its colour exactly, and only as much of it as the
  # profile's headroom allows. Then saturation, eased toward the pixel's own
  # brightness, which keeps both its brightness and its hue and gives up only
  # how strong the colour is.
  module Gamut
    module_function

    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Where the chroma easing starts to be felt, so that a pixel only just over
    # the line is barely touched.
    KNEE = 0.92

    # `srgb` is float sRGB, which may sit outside 0..1, and `headroom` is how
    # far a pixel may be darkened before its colour is eased instead.
    def fit(srgb, headroom = 0.0)
      linear = Colour.to_linear(srgb)
      linear = Highlights.pull(linear, headroom) if headroom.to_f.positive?
      Colour.to_srgb(Colour.clamp01(desaturate(linear))).copy(interpretation: :srgb)
    end

    # What is still over the top comes out of chroma: each pixel is eased
    # toward its own brightness by exactly as much as it takes to fit.
    def desaturate(linear)
      peak = Highlights.peak_of(linear)
      y = (linear * LUMA).bandmean * 3.0
      held = (y > KNEE).ifthenelse(KNEE, y)
      room = peak - held
      keep = (held * -1.0 + 1.0) / (room < 1e-5).ifthenelse(1e-5, room)
      keep = (keep > 1.0).ifthenelse(1.0, keep)
      keep = (keep < 0.0).ifthenelse(0.0, keep)
      held + (linear - held) * keep
    end
  end
end
