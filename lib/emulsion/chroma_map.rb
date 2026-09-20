module Emulsion
  # A film's colour bent onto a reference film's, beyond what per-channel
  # gains can reach.
  #
  # Gains put greys where the reference puts them, since that is what they are
  # measured on. They leave saturated subjects wherever the film's own dyes
  # left them: Lucky's sunlit stone stays two stops short of blue however the
  # greys are handled. This measures the shape of each film's colour, as the
  # spread of red and blue against green, and fits the straight map that takes
  # one shape onto the other. Where a channel is exhausted, the map reaches it
  # through the channels that are not.
  #
  # It is inference, not measurement: the two films photographed similar places
  # rather than the same frames, so the map is only as good as that likeness.
  class ChromaMap
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Tones the map is fitted over. The ends are left out: shadows are noise
    # and highlights are clipped, and neither says much about colour.
    BANDS = (2..6).freeze

    # How far the map may stretch the colour, so a bad fit cannot run away.
    MAX_STRETCH = 2.5

    attr_reader :matrix, :offset

    # Pixels are [red, green, blue] in linear light, already through the
    # per-channel correction, so only the shape of what is left is fitted.
    def self.fit(film_pixels, reference_pixels)
      film = moments(film_pixels)
      reference = moments(reference_pixels)
      return nil unless film && reference

      # Match spread and centre on each axis: the plainest map that takes one
      # cloud onto the other without needing the same frames in both.
      scale = (0..1).map do |axis|
        next 1.0 if film[:spread][axis] <= 1e-6

        (reference[:spread][axis] / film[:spread][axis]).clamp(1.0 / MAX_STRETCH, MAX_STRETCH)
      end
      shift = (0..1).map { |axis| reference[:centre][axis] - scale[axis] * film[:centre][axis] }
      new(scale, shift)
    end

    # The centre and spread of the colour cloud, in stops of red and blue
    # against green, over the tones worth fitting.
    def self.moments(pixels)
      points = []
      pixels.each do |px|
        next if px.min <= 1e-5 || px.max >= ColourBalance::CLIPPED
        next unless BANDS.cover?(ColourBalance.tone_index(ColourBalance.luma(px)))

        points << [Math.log2(px[0] / px[1]), Math.log2(px[2] / px[1])]
      end
      return nil if points.size < 2000

      centre = (0..1).map { |axis| ColourBalance.percentile(points.map { |p| p[axis] }, 50) }
      spread = (0..1).map do |axis|
        values = points.map { |p| p[axis] }
        (ColourBalance.percentile(values, 84) - ColourBalance.percentile(values, 16)) / 2.0
      end
      { centre: centre, spread: spread }
    end

    def self.from_cache(data)
      new(data[:matrix], data[:offset])
    end

    def initialize(matrix, offset)
      @matrix = matrix
      @offset = offset
    end

    def strength
      @strength || 1.0
    end

    attr_writer :strength

    # Red and blue are moved against green, which keeps brightness where the
    # tone work put it. Where `lost` says a pixel's blue has nothing left, the
    # map steps aside: stretching a colour that was never recorded only makes
    # a louder version of the wrong answer.
    def apply(srgb, lost = nil)
      return srgb if strength <= 0

      linear = Colour.to_linear(srgb)
      green = (linear[1] < 1e-5).ifthenelse(1e-5, linear[1])
      bands = [0, 2].map.with_index do |channel, axis|
        value = (linear[channel] < 1e-5).ifthenelse(1e-5, linear[channel])
        stops = (value / green).log / Math.log(2)
        moved = stops * scale_at(axis) + shift_at(axis)
        green * (moved * Math.log(2)).exp
      end
      mapped = bands[0].bandjoin([linear[1], bands[1]])
      mapped = linear + (mapped - linear) * (lost * -1.0 + 1.0) if lost
      Colour.to_srgb(Colour.clamp01(mapped)).copy(interpretation: :srgb)
    end

    def scale_at(axis)
      1.0 + (@matrix[axis] - 1.0) * strength
    end

    def shift_at(axis)
      @offset[axis] * strength
    end

    def to_h
      { "matrix" => @matrix, "offset" => @offset }
    end

    def report
      format("  colour shape stretched red x%.2f%+.2f, blue x%.2f%+.2f stops",
             scale_at(0), shift_at(0), scale_at(1), shift_at(1))
    end
  end
end
