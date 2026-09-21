module Emulsion
  # The dark corners a camera and a scanner leave on every frame.
  #
  # One frame cannot tell a dark corner from a dark subject, but a roll can:
  # across enough frames the subjects cancel and what remains is the falloff.
  # It is measured against distance from the centre, which is how a lens loses
  # light, so frames shot upright and on their side measure together. Each
  # channel is measured on its own, since a corner usually loses its colour as
  # well as its light.
  class FlatField
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    BINS = 24

    # Frames sampled from the roll, and how wide each is measured.
    FRAMES = 14
    WIDTH = 480

    # Trimmed off each side after cropping, more when the borders were not
    # found, and the share of the width at which subjects are blurred away.
    SAFETY = 0.02
    UNCROPPED_SAFETY = 0.09
    BLUR = 0.06

    # The most any corner may be lifted. Past this a corner is dark because
    # the pictures are, and lifting only magnifies grain.
    MAX_LIFT = 1.7

    # How far a single channel may be lifted away from the other two. A real
    # corner loses a little colour with its light; a crushed channel reads as
    # losing far more than it did.
    TINT_LIMIT = 0.35

    # Rings at the very corner, where a camera's own mask can cut in sharply,
    # are measured but not fitted.
    IGNORED_RINGS = 3

    # Rings needed before a roll is fitted at all.
    MIN_RINGS = 6

    attr_reader :model

    # Fits from a roll's files. `crop` takes a path and its image and returns
    # where the picture sits, so that scanner borders stay out of it.
    def self.fit(paths, verbose: true, &crop)
      step = [paths.size / FRAMES, 1].max
      frames = paths.each_slice(step).map(&:first).first(FRAMES)
      rings = Array.new(3) { Array.new(BINS) { [] } }
      frames.each_with_index do |path, i|
        print "\r  measuring falloff #{i + 1}/#{frames.size}" if verbose
        measured = measure(path, &crop) or next

        measured.each_with_index do |channel, c|
          channel.each_with_index { |value, bin| rings[c][bin] << value if value }
        end
      end
      puts if verbose
      new(rings.map { |channel| curve_through(channel.map { |values| median(values) }) })
    end

    # A frame's brightness by distance from its centre, per channel, each ring
    # relative to the middle of the frame so a dark or bright picture counts
    # the same.
    def self.measure(path)
      image = Vips::Image.thumbnail(path, WIDTH, size: :down).copy_memory
      image = image[0..2] if image.bands > 3
      image = image.cast(:float) / (image.format == :ushort ? 65535.0 : 255.0)
      area = block_given? ? yield(path, image) : nil
      share = area ? SAFETY : UNCROPPED_SAFETY
      image = inset(area ? image.extract_area(*area) : image, share)
      # Light is lost in proportion, so the rings are measured in linear light.
      image = Colour.to_linear(image).gaussblur([image.width * BLUR, 1].max)
      # Rings are counted against the whole picture, so a frame trimmed harder
      # simply has nothing to say about the outer ones.
      bins = bin_index(image.width, image.height, 1.0 - 2 * share)
      counts = read_row(Vips::Image.black(image.width, image.height).new_from_image(1.0)
                                   .hist_find_indexed(bins))
      (0..2).map do |c|
        # A uchar index gives a row of 256 whatever the rings, so take ours.
        sums = read_row(image[c].hist_find_indexed(bins)).first(BINS)
        rings = sums.each_index.map { |i| counts[i].to_f < 32 ? nil : sums[i] / counts[i] }
        middle = rings.first(BINS / 4).compact
        return nil if middle.empty? || middle.sum <= 1e-6

        centre = middle.sum / middle.size
        rings.map { |value| value && value / centre }
      end
    end

    # A little more off each side, since the step out of the picture is soft.
    def self.inset(image, share)
      dx = (image.width * share).to_i
      dy = (image.height * share).to_i
      image.extract_area(dx, dy, image.width - 2 * dx, image.height - 2 * dy)
    end

    # Which ring each pixel falls in, from the centre out to the corner.
    def self.bin_index(width, height, scale = 1.0)
      ring = (radius(width, height) * scale * (BINS - 1)).rint
      (ring > BINS - 1).ifthenelse(BINS - 1, ring).cast(:uchar)
    end

    # Distance from the centre, 1.0 at the corners.
    def self.radius(width, height)
      centre = Vips::Image.xyz(width, height) - [width / 2.0, height / 2.0]
      ((centre[0] * centre[0] + centre[1] * centre[1])**0.5) /
        ((width * width + height * height)**0.5 / 2.0)
    end

    def self.median(values)
      values.empty? ? nil : Measurements.percentile(values.sort, 50)
    end

    def self.read_row(row)
      row.cast(:double).write_to_memory.unpack("d*")
    end

    # A lens loses light smoothly with distance, so the rings are turned into
    # a curve in r squared. Fitting rather than using the rings as measured
    # keeps grain in one ring from becoming a visible band.
    def self.curve_through(values)
      usable = values.each_index.select { |i| values[i] && i <= BINS - 1 - IGNORED_RINGS }
      return [1.0, 0.0, 0.0] if usable.size < MIN_RINGS

      rows = usable.map { |i| [1.0, radius_of(i)**2, radius_of(i)**4] }
      solve(rows, usable.map { |i| values[i] }) || [1.0, 0.0, 0.0]
    end

    def self.radius_of(bin)
      bin.to_f / (BINS - 1)
    end

    # Least squares through the normal equations, small enough to solve here.
    def self.solve(rows, values)
      size = rows.first.size
      matrix = Array.new(size) { Array.new(size + 1, 0.0) }
      rows.each_with_index do |row, k|
        size.times do |i|
          size.times { |j| matrix[i][j] += row[i] * row[j] }
          matrix[i][size] += row[i] * values[k]
        end
      end
      size.times do |i|
        pivot = (i...size).max_by { |r| matrix[r][i].abs }
        return nil if matrix[pivot][i].abs < 1e-12

        matrix[i], matrix[pivot] = matrix[pivot], matrix[i]
        ((i + 1)...size).each do |r|
          factor = matrix[r][i] / matrix[i][i]
          (i..size).each { |c| matrix[r][c] -= factor * matrix[i][c] }
        end
      end
      answer = Array.new(size, 0.0)
      (size - 1).downto(0) do |i|
        total = matrix[i][size] - ((i + 1)...size).sum { |j| matrix[i][j] * answer[j] }
        answer[i] = total / matrix[i][i]
      end
      answer
    end

    def self.from_cache(data)
      new(data[:model])
    end

    # Three curves, one per channel, each [centre, r squared, r to the fourth].
    def initialize(model)
      @model = model
    end

    def strength
      @strength || 1.0
    end

    attr_writer :strength

    # The furthest out the curve is trusted, since it was never fitted to the
    # very corner.
    def limit
      1.0 - IGNORED_RINGS.to_f / (BINS - 1)
    end

    # What the roll keeps out there, per channel, as a share of the centre.
    def corners
      r = limit
      @model.map do |centre, second, fourth|
        centre.abs < 1e-6 ? 1.0 : ((centre + second * r**2 + fourth * r**4) / centre).clamp(0.05, 4.0)
      end
    end

    def flat?
      corners.all? { |value| (1.0 - value).abs < 0.02 }
    end

    # Held flat past the last ring fitted, since a curve in r to the fourth
    # runs away as soon as it is asked about radii it never saw.
    def apply(image)
      return image if flat?

      r = self.class.radius(image.width, image.height)
      r = (r > limit).ifthenelse(limit, r)
      squared = r * r
      gains = (0..2).map do |c|
        centre, second, fourth = @model[c]
        falloff = (squared * second + squared * squared * fourth + centre) / centre
        (falloff < 1e-3).ifthenelse(1e-3, falloff)**-1.0
      end
      # A corner does lose colour along with light, but not by much, and a
      # channel that reads as far down as Phoenix's red is reading its own
      # crushed floor rather than the falloff. Each channel is held to within
      # TINT_LIMIT stops of what the three of them do together.
      brightness = gains[0] * LUMA[0] + gains[1] * LUMA[1] + gains[2] * LUMA[2]
      gains = gains.map { |gain| brightness * tint_held(gain, brightness) }
      held = (brightness > MAX_LIFT).ifthenelse(brightness**-1.0 * MAX_LIFT, 1.0)
      linear = Colour.to_linear(image)
      bands = (0..2).map { |c| linear[c] * ((gains[c] * held - 1.0) * strength + 1.0) }
      Colour.to_srgb(bands[0].bandjoin([bands[1], bands[2]])).copy(interpretation: :srgb)
    end

    # How far one channel's lift may sit from the lift the three make together,
    # as a factor rather than in stops, so it can be multiplied straight back.
    def tint_held(gain, brightness)
      stops = (gain / brightness).log / Math.log(2)
      held = (stops > TINT_LIMIT).ifthenelse(TINT_LIMIT, stops)
      held = (held < -TINT_LIMIT).ifthenelse(-TINT_LIMIT, held)
      (held * Math.log(2)).exp
    end

    def to_h
      { "model" => @model }
    end

    def report
      return "  corners are even, so nothing is lifted" if flat?

      stops = corners.map { |value| Math.log2(1.0 / value) }
      format("  corners down %.2f, %.2f, %.2f stops in red, green and blue, lifted by %.0f%%",
             *stops, strength * 100)
    end
  end
end
