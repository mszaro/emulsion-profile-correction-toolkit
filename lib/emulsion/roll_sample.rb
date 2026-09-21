module Emulsion
  # A few thousand pixels from every frame in a roll, for the roll-wide fits.
  #
  # Taken by stride rather than by scaling down, since scaling averages
  # neighbours and would narrow the very colour spread being measured.
  class RollSample
    LUMA = [0.2126, 0.7152, 0.0722].freeze
    INSET = 0.05

    # Channels and luma in 0..255, and how many pixels came from each frame.
    Pixels = Data.define(:r, :g, :b, :y, :frame_sizes)

    # A crop block takes a frame and returns where its picture sits, so that
    # scanner borders stay out of the roll's statistics. A skip block takes the
    # cropped frame and returns a mask of pixels that have no business in them,
    # a sky being the one that matters.
    def self.collect(paths, per_frame: 6000, verbose: true, skip: nil, &crop)
      r = []
      g = []
      b = []
      y = []
      frame_sizes = []

      paths.each_with_index do |path, i|
        print "\r  sampling #{i + 1}/#{paths.size}" if verbose
        image = Vips::Image.new_from_file(path, access: :random)
        image = image.bandjoin([image, image]) if image.bands == 1
        image = image[0..2] if image.bands > 3
        image = image.cast(:float)
        image /= 257.0 if image.max > 256
        area = crop&.call(image / 255.0)
        image = image.extract_area(*area) if area

        w = image.width
        h = image.height
        dx = (w * INSET).to_i
        dy = (h * INSET).to_i
        inner = image.extract_area(dx, dy, w - 2 * dx, h - 2 * dy)

        factor = Math.sqrt(inner.width * inner.height / per_frame.to_f).floor
        inner = inner.subsample(factor, factor) if factor > 1

        before = r.size
        raw = inner.cast(:float).write_to_memory.unpack("f*")
        dropped = skipped_at(skip, image, dx, dy, factor)
        raw.each_slice(inner.bands).with_index do |px, at|
          next if dropped && dropped[at] > 0.5

          r << px[0]
          g << px[1]
          b << px[2]
          y << (LUMA[0] * px[0] + LUMA[1] * px[1] + LUMA[2] * px[2])
        end
        frame_sizes << (r.size - before)
      end
      puts if verbose
      Pixels.new(r: r, g: g, b: b, y: y, frame_sizes: frame_sizes)
    end

    # The skip mask taken at the same grid as the pixels, or nil when there is
    # nothing to skip on this frame.
    def self.skipped_at(skip, image, dx, dy, factor)
      mask = skip&.call(image / 255.0)
      return nil unless mask

      inner = mask.extract_area(dx, dy, image.width - 2 * dx, image.height - 2 * dy)
      inner = inner.subsample(factor, factor) if factor > 1
      inner.cast(:float).write_to_memory.unpack("f*")
    end
  end
end
