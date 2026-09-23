module Emulsion
  # A sheet of every frame in a roll, named, for looking over the whole roll
  # at once. Built from the frames as they are corrected, so it costs a
  # thumbnail each rather than a second pass over the output.
  class ContactSheet
    ACROSS = 6
    TILE = 460
    CAPTION = 36
    GAP = 8
    BACKGROUND = [24, 24, 24].freeze
    INK = [210, 210, 210].freeze
    HEADING_INK = [235, 235, 235].freeze

    def initialize(title)
      @title = title
      @tiles = []
    end

    # `image` is a float sRGB frame in 0..1, `name` what to write under it.
    def add(image, name)
      tile = (image * 255).cast(:uchar).thumbnail_image(TILE, height: TILE - CAPTION, size: :down)
      tile = tile.embed((TILE - tile.width) / 2, (TILE - CAPTION - tile.height) / 2,
                        TILE, TILE - CAPTION, extend: :background, background: BACKGROUND)
      @tiles << tile.join(caption(name, TILE), :vertical, background: BACKGROUND)
      self
    end

    def empty?
      @tiles.empty?
    end

    def write(path)
      return nil if empty?

      grid = Vips::Image.arrayjoin(@tiles, across: ACROSS, shim: GAP, background: BACKGROUND)
      sheet = banner(grid.width).join(grid, :vertical, background: BACKGROUND)
      sheet.write_to_file(path, Q: 86, strip: true)
      path
    end

    private

    # Frame numbers read better without the zeros the lab pads them with.
    def caption(name, width)
      text(name.to_s.sub(/\A0+(?=.)/, ""), 150, INK, width, CAPTION, 8, 4)
    end

    def banner(width)
      text(@title, 220, HEADING_INK, width, nil, 10, 12, bold: true)
    end

    # A band of one colour with the string written on it. The text is shrunk to
    # fit when a long roll name would otherwise run off the end.
    def text(string, dpi, ink, width, height, left, top, bold: false)
      mask = Vips::Image.text(string, dpi: dpi, font: bold ? "sans bold" : "sans")
      room = width - 2 * left
      mask = mask.resize(room.to_f / mask.width) if mask.width > room
      mask.ifthenelse(ink, BACKGROUND, blend: true)
          .embed(left, top, width, height || (mask.height + 2 * top), extend: :background,
                                                                      background: BACKGROUND)
          .cast(:uchar).copy(interpretation: :srgb)
    end
  end
end
