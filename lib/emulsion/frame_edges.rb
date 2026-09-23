module Emulsion
  # What a scanner leaves around the picture, when it leaves anything.
  #
  # A full frame scan runs wider than the film, so each side reads outward as
  # picture, then the unexposed rebate, then bright overscan where the light
  # missed the film entirely. The rebate is worth finding: it is what this
  # scanner made of no exposure at all, which is the frame's own black floor,
  # measured rather than guessed from the picture. Plenty of labs crop to the
  # picture and leave none of this, so nothing here is required and every
  # answer may be nil.
  class FrameEdges
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # How far in from each side to look, as a share of that side.
    SEARCH = 0.12

    # The rebate is dark and even. Evenness is what separates it from a
    # picture that happens to be dark along one side.
    REBATE_LEVEL = 0.35
    OVERSCAN_LEVEL = 0.80
    FLAT_SD = 0.05

    # The least the rebate may measure, as a share of the side searched, and
    # how far in it may begin.
    MIN_REBATE = 0.03
    MAX_START = 0.5

    # The most that may be cropped from any side, and how far back from the
    # edge found to keep, since the step into the picture is
    # softened by the scanner.
    MARGIN = 0.01
    MAX_CROP = 0.08

    # Sides that must agree before the borders are believed.
    MIN_SIDES = 2

    # Rows or columns sampled along a side.
    SAMPLES = 600

    attr_reader :sides

    # Read at one size whatever the scan's own. The rebate is found by being
    # dark and even, and at 6144px the film's own grain is nearly as uneven as
    # FLAT_SD allows, so whether a frame's border is found comes down to how
    # grainy that frame happens to be: on one roll it was found on one frame in
    # eight at scan size and on eight in eight here.
    WORK = 1200

    # Looks along all four sides of a float sRGB image in 0..1.
    def self.detect(image)
      scale = WORK.to_f / image.width
      read = scale < 1.0 ? image.resize(scale) : image
      sides = %i[left right top bottom].to_h { |side| [side, scan_side(read, side)] }
      sides = sides.transform_values { |side| side && side.merge(edge: (side[:edge] / scale).round) } if scale < 1.0
      new(sides, image.width, image.height)
    end

    # Reads one side inward for the rebate: the first stretch that is both
    # dark and even, deep enough to be film rather than a shadow in the
    # picture, and ending before the search does, since the picture has to
    # start somewhere. What comes before it, bright overscan or the blurred
    # step between the two, does not matter.
    def self.scan_side(image, side)
      strip = strip_for(image, side)
      means, deviations = profile(strip)
      depth = means.size
      minimum = [(depth * MIN_REBATE).ceil, 4].max
      margin = (depth * MARGIN).ceil

      start = nil
      depth.times do |index|
        if means[index] <= REBATE_LEVEL && deviations[index] <= FLAT_SD
          start ||= index
        elsif start
          break if start > depth * MAX_START || index - start < minimum

          return { edge: index + margin, floor: floor_of(strip, start, index) }
        end
      end
      # No rebate on this side, but bright overscan is still not picture.
      bright = 0
      bright += 1 while bright < depth && means[bright] >= OVERSCAN_LEVEL && deviations[bright] <= FLAT_SD
      bright >= minimum ? { edge: bright + margin, floor: nil } : nil
    end

    # A band along one side, always oriented so that reading left to right in
    # the returned image is reading inward from that side.
    def self.strip_for(image, side)
      w = image.width
      h = image.height
      case side
      when :left then image.extract_area(0, h / 4, (w * SEARCH).to_i, h / 2)
      when :right then image.extract_area(w - (w * SEARCH).to_i, h / 4, (w * SEARCH).to_i, h / 2).fliphor
      when :top then image.extract_area(w / 4, 0, w / 2, (h * SEARCH).to_i).rot90.fliphor
      else image.extract_area(w / 4, h - (h * SEARCH).to_i, w / 2, (h * SEARCH).to_i).rot90
      end
    end

    # Mean and deviation of luma along each step inward.
    def self.profile(strip)
      luma = (strip * LUMA).bandmean * 3.0
      down = [strip.height / SAMPLES, 1].max
      luma = luma.subsample(1, down) if down > 1
      mean = luma.shrinkv(luma.height)
      spread = ((luma * luma).shrinkv(luma.height) - mean * mean)
      spread = (spread < 0).ifthenelse(0, spread)**0.5
      [read_row(mean), read_row(spread)]
    end

    def self.read_row(row)
      row.cast(:float).write_to_memory.unpack("f*")
    end

    # The rebate's colour in 0..255, taken from the middle of the run so that
    # neither the overscan nor the picture bleeds in.
    def self.floor_of(strip, from, to)
      inset = ((to - from) * 0.25).ceil
      band = strip.extract_area(from + inset, 0, [to - from - 2 * inset, 1].max, strip.height)
      (0..2).map { |c| band[c].avg * 255.0 }
    end

    def initialize(sides, width, height)
      @sides = sides
      @width = width
      @height = height
    end

    # Two sides with a rebate is enough to believe the film is in the scan.
    def found?
      @sides.values.count { |side| side && side[:floor] } >= MIN_SIDES
    end

    # Where the picture sits inside the scan, or nil when the sides disagree
    # or there was no border to find.
    def picture
      return nil unless found?

      left = crop_at(:left, @width)
      right = @width - crop_at(:right, @width)
      top = crop_at(:top, @height)
      bottom = @height - crop_at(:bottom, @height)
      return nil if right - left < @width / 2 || bottom - top < @height / 2

      [left, top, right - left, bottom - top]
    end

    # A side is only trusted to crop as far as MAX_CROP, so a dark edge read
    # as film can never eat into the picture.
    #
    # Once the film is known to be in the scan, a side that found nothing
    # borrows from the side opposite, since the gate is the same width top and
    # bottom and left and right. A rebate fogged by a light leak reads too
    # bright to be film, and without this it stays in the picture as a
    # coloured strip.
    def crop_at(side, size)
      edge = edge_of(side) || edge_of(OPPOSITE[side])
      edge && edge <= size * MAX_CROP ? edge : 0
    end

    OPPOSITE = { left: :right, right: :left, top: :bottom, bottom: :top }.freeze

    def edge_of(side)
      @sides[side] && @sides[side][:edge]
    end

    # The frame's own black floor in 0..255, median of the sides that found a
    # rebate, or nil when none did.
    def floor
      floors = @sides.values.compact.filter_map { |side| side[:floor] }
      return nil if floors.size < MIN_SIDES

      (0..2).map { |c| Measurements.percentile(floors.map { |f| f[c] }.sort, 50) }
    end

    # The floor as ColourBalance keeps its offsets: how far each channel sits
    # above the lowest one.
    def floor_offsets
      measured = floor
      measured && measured.map { |v| v - measured.min }
    end

    def report
      return "  no film border in the scans, so the black floor comes from the frames" unless found?

      format("  film rebate on %d sides, black floor red %.1f green %.1f blue %.1f",
             @sides.values.count { |side| side&.fetch(:floor) }, *floor)
    end
  end
end
