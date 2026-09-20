module Emulsion
  # What to render where a channel has nothing left to say.
  #
  # Lucky's blue layer records almost nothing on warm subjects in warm light:
  # sunlit stone arrives with its blue three stops under where a grey of the
  # same brightness sits, and once the film's black floor comes off there is
  # not enough left to say how yellow the stone really was. A per-channel
  # correction cannot invent it, so those pixels come out vividly yellow.
  #
  # This eases them toward grey instead, by how far their blue has fallen.
  # Pixels whose blue still carries something keep their colour, so a blue sky
  # or a red awning in the same frame is untouched.
  class LostColour
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Stops below a grey of the same brightness at which blue starts to be
    # doubted, and where nothing of it is believed.
    DOUBTED = 1.6
    LOST = 3.6

    # The most colour that is ever taken away, so that even a hopeless pixel
    # keeps a trace of the warmth it was photographed in.
    MAX_PULL = 0.75

    # `neutral` is the reference's [red, blue] per tone, so that how blue a
    # grey should be is read from the reference rather than assumed to be flat.
    def self.apply(srgb, neutral, amount)
      return srgb if amount <= 0

      linear = Colour.to_linear(srgb)
      y = (linear * LUMA).bandmean * 3.0
      pull = lost(linear, y, neutral) * (amount * MAX_PULL)
      Colour.to_srgb(y + (linear - y) * (pull * -1.0 + 1.0)).copy(interpretation: :srgb)
    end

    # How far gone each pixel's blue is, 0 where it still says something and 1
    # where nothing of it is believed. Shared with the chroma map, which has
    # no business reshaping colour that is no longer there.
    def self.lost(linear, luma, neutral)
      safe = (luma < 1e-5).ifthenelse(1e-5, luma)
      # What a grey of this brightness holds in blue, as the reference renders
      # it, and how far under that this pixel's blue sits.
      expected = safe * expectation(luma, neutral)
      short = (expected / (linear[2] < 1e-5).ifthenelse(1e-5, linear[2])).log / Math.log(2)
      ramp(short)
    end

    # How much blue a grey carries at each brightness, as a curve over the
    # reference's tone bands.
    def self.expectation(y, neutral)
      values = (0..255).map do |i|
        tone = Colour.srgb_to_linear_scalar(i / 255.0)
        2**blue_at(tone, neutral)
      end
      index = (Colour.to_srgb(y) * 255.0).cast(:uchar)
      index.maplut(Vips::Image.new_from_array([values]))
    end

    def self.blue_at(tone, neutral)
      tones = ColourBalance::TONES
      return neutral.first[1] if tone <= tones.first
      return neutral.last[1] if tone >= tones.last

      hi = tones.index { |t| t >= tone }
      span = Math.log(tones[hi]) - Math.log(tones[hi - 1])
      t = span.zero? ? 0.0 : (Math.log(tone) - Math.log(tones[hi - 1])) / span
      neutral[hi - 1][1] * (1 - t) + neutral[hi][1] * t
    end

    # Nothing under DOUBTED stops, everything over LOST, smooth between.
    def self.ramp(short)
      t = ((short - DOUBTED) / (LOST - DOUBTED))
      t = (t < 0).ifthenelse(0, (t > 1).ifthenelse(1, t))
      t * t * (t * -2.0 + 3.0)
    end
  end
end
