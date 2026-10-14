module FilmScan
  # Which way up each scan goes. The lab's orientation tag decides, unless the
  # overrides file gives the frame an orientation of its own, for a portrait
  # frame the lab left untagged or a tag it got wrong. Everything that opens a
  # scan asks here, so the sky detector, the roll's analysis, the contact
  # sheet and the written file all agree on where the top is.
  module Orientation
    # Upright, upside down and the two quarter turns, numbered as EXIF numbers
    # them. Film is never mirrored, and the sky detector declines a flip.
    VALUES = [1, 3, 6, 8].freeze

    class << self
      # The run's overrides, by the scan's path.
      attr_writer :overrides

      def overrides
        @overrides ||= {}
      end

      # How a scan is turned to stand upright: its override, else its tag, and
      # 1 when it has neither.
      def of(path)
        overrides.fetch(path) { tag(path) }
      end

      # The lab's tag, 1 when it has none.
      def tag(path)
        header = Vips::Image.new_from_file(path)
        header.get_typeof("orientation").zero? ? 1 : header.get("orientation")
      rescue Vips::Error
        1
      end

      # A scan as loaded, marked with its override where it has one, so what
      # reads the orientation off the image sees that in place of the tag.
      def apply(image, path)
        turn = overrides[path]
        turn ? marked(image, turn) : image
      end

      # A shrunk copy stood upright. libvips shrinks a tagged scan to `width`
      # as stored and then turns it, so one with an override goes the same way.
      def thumbnail(path, width)
        turn = overrides[path]
        return Vips::Image.thumbnail(path, width, size: :down) unless turn

        upright(Vips::Image.thumbnail(path, width, size: :down, no_rotate: true), turn)
      end

      # The pixels turned the way `orientation` says, with no tag left to turn
      # them again.
      def upright(image, orientation)
        marked(image, orientation).autorot
      end

      private

      def marked(image, orientation)
        image = image.copy
        image.set_type(GObject::GINT_TYPE, "orientation", orientation)
        image
      end
    end
  end
end
