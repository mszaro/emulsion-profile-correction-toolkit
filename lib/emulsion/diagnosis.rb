module Emulsion
  # What the toolkit thinks is wrong with a roll, said out loud before anything
  # is done about it.
  #
  # Each finding is a named fault with a severity in the units it is measured
  # in, and a confidence that is how far past the line between absent and
  # present it sits, scaled by how much of the roll it was read from. The lines
  # were drawn from the rolls in the Milan and Switzerland batch, with Superia,
  # which the lab scanned properly, as the case where every fault is absent.
  class Diagnosis
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # Frames read, and at what size. Enough for the roll to show through its
    # scenes, small enough to stay quick next to a render.
    FRAMES = 8
    WIDTH = 1000

    # The side of the square read from each frame for its grain.
    GRAIN_CROP = 1600

    # Frames needed before a finding counts at full weight.
    FULL_SUPPORT = 6

    Finding = Data.define(:name, :label, :severity, :unit, :confidence, :detail) do
      def present?
        confidence >= 0.5
      end
    end

    # Each fault, the value at which it is absent and the value at which it is
    # present, and what it is measured in. The drift line sits above the seven
    # Superia rolls, which read 0.18 to 0.30 with no drift to find: that much
    # is the frame fit reading scenes, not the lab moving.
    LINES = {
      lab_drift: [0.30, 0.45, "stops"],
      cast: [0.35, 0.60, "stops"],
      blue_exhausted: [0.003, 0.05, "of the frame"],
      crushed_channel: [8.0, 20.0, "levels"],
      clipped: [0.005, 0.03, "of the frame"],
      grain: [1.15, 1.6, "x usual"],
      corner_tint: [0.20, 0.35, "stops"]
    }.freeze

    LABELS = {
      lab_drift: "lab rebalanced each frame",
      cast: "the roll sits off the reference",
      blue_exhausted: "blue has nothing left on warm subjects",
      crushed_channel: "a channel is crushed at black",
      clipped: "a channel is clipped at white",
      grain: "grainier than a well scanned roll",
      corner_tint: "the corner lift would tint the corners"
    }.freeze

    attr_reader :findings

    def self.of(paths, reference:, flat: nil)
      step = [paths.size / FRAMES, 1].max
      chosen = paths.each_slice(step).map(&:first).first(FRAMES)
      new(frames_of(chosen), reference, flat, grain_of(chosen))
    end

    # Grain is read at the scan's own resolution, from the middle of each frame,
    # since shrinking a frame averages its grain away.
    def self.grain_of(paths)
      paths.filter_map do |path|
        image = Vips::Image.new_from_file(path, access: :random)
        side = [image.width, image.height, GRAIN_CROP].min
        crop = image.extract_area((image.width - side) / 2, (image.height - side) / 2, side, side)
        crop = crop[0..2] if crop.bands > 3
        crop = crop.cast(:float) / (crop.format == :ushort ? 65535.0 : 255.0)
        Detail.measure(crop.copy_memory)&.grain
      end
    end

    # Evenly through the roll, cropped to the picture where the borders show.
    def self.frames_of(paths)
      paths.map do |path|
        image = Vips::Image.thumbnail(path, WIDTH, size: :down).copy_memory
        image = image[0..2] if image.bands > 3
        image = image.cast(:float) / (image.format == :ushort ? 65535.0 : 255.0)
        area = FrameEdges.detect(image).picture
        area ? image.extract_area(*area) : image
      end
    end

    # How far past the line between absent and present a value sits, 0 to 1.
    def self.ramp(value, absent, present)
      ((value - absent) / (present - absent)).clamp(0.0, 1.0)
    end

    # How much the lab moved its balance from one frame to the next, as the
    # median distance in stops between each frame's own neutral and the roll's.
    def self.lab_drift(frames, reference)
      drifts = frames.filter_map do |image|
        fit = ColourBalance.fit_frame(image, reference.neutral, limit: ColourBalance::FRAME_MAX_STOPS)
        next unless fit

        mid = fit.gains[2..5]
        [mid.sum { |g| g[0] - g[1] } / mid.size, mid.sum { |g| g[2] - g[1] } / mid.size]
      end
      return [nil, drifts] if drifts.size < 3

      centre = (0..1).map { |c| Measurements.percentile(drifts.map { |d| d[c] }.sort, 50) }
      distances = drifts.map { |d| Math.hypot(d[0] - centre[0], d[1] - centre[1]) }
      [Measurements.percentile(distances.sort, 50), drifts]
    end

    # How sure a single frame is that one of its channels sits crushed at black
    # while another holds something, 0 to 1. Read the way the roll finding is.
    def self.crushed(srgb)
      floors = (0..2).map { |c| (Colour.clamp01(srgb[c]) * 255.0).cast(:uchar).percent(1).to_f }
      low = floors.min
      return 0.0 if low > 3
    
      ramp(floors.max - low, *LINES[:crushed_channel].first(2))
    end
    
    def initialize(frames, reference, flat, grains = [])
      @grains = grains
      @frames = frames
      @reference = reference
      @support = [frames.size.to_f / FULL_SUPPORT, 1.0].min
      @findings = [drift_and_cast, blue_exhausted, crushed_channel, clipped, grain, corner_tint(flat)]
                  .flatten.compact
    end

    def [](name)
      @findings.find { |finding| finding.name == name }
    end

    # How confident the diagnosis is that a fault is there, 0 when it was not
    # measured.
    def confidence(name)
      self[name]&.confidence || 0.0
    end

    # The stage that answers each fault, and whether it should be on or off
    # when the fault is there. Corner tint is the one a stage makes worse.
    STAGES = {
      lab_drift: [:frame_balance, "frame balance", :on],
      cast: [:roll_balance, "roll balance toward the reference", :on],
      blue_exhausted: [:lost_colour, "easing lost colour toward grey", :on],
      crushed_channel: [nil, "shadow lift held back on the frame", :on],
      clipped: [:highlight_headroom, "highlight headroom", :on],
      grain: [:chroma, "chroma denoise", :on],
      corner_tint: [:flat_field, "corner lift", :off]
    }.freeze

    # Each finding next to what the profile does about it: handled, LEFT when a
    # fault is there and its stage is off, SPENT when a stage works on a fault
    # the roll does not have, AT RISK when a stage is on that makes the fault
    # worse.
    def audit(options)
      lines = ["  what the profile does about it:"]
      @findings.each do |f|
        setting, stage, wants = STAGES.fetch(f.name)
        on = setting.nil? || (options[setting].to_f.positive? && (f.name != :cast || options[:reference]))
        outcome = if wants == :off
                    f.present? && on ? "AT RISK" : "handled"
                  elsif f.present?
                    on ? "handled" : "LEFT"
                  elsif on && %i[lab_drift cast blue_exhausted clipped].include?(f.name)
                    "SPENT"
                  else
                    "quiet"
                  end
        lines << format("    %-8s %-50s %s%s", outcome, f.label, stage,
                        setting ? " (#{setting}: #{options[setting].inspect})" : "")
      end
      lines.join("\n")
    end

    def report
      lines = ["  what the roll shows, from #{@frames.size} frames:"]
      @findings.each do |f|
        lines << format("    %-50s %6.3f %-13s confidence %.2f%s", f.label, f.severity, f.unit,
                        f.confidence, f.detail ? "  (#{f.detail})" : "")
      end
      lines.join("\n")
    end

    private

    def finding(name, severity, detail = nil)
      absent, present, unit = LINES.fetch(name)
      confidence = self.class.ramp(severity, absent, present) * @support
      Finding.new(name: name, label: LABELS.fetch(name), severity: severity, unit: unit,
                  confidence: confidence.round(3), detail: detail)
    end

    def drift_and_cast
      return [] unless @reference

      drift, drifts = self.class.lab_drift(@frames, @reference)
      return [] unless drift

      centre = (0..1).map { |c| Measurements.percentile(drifts.map { |d| d[c] }.sort, 50) }
      [finding(:lab_drift, drift),
       finding(:cast, Math.hypot(*centre), format("red %+.2f, blue %+.2f", *centre))]
    end

    # Midtone pixels whose blue sits three stops or more under their green,
    # once each channel's own floor is off: too little left to say what colour
    # the subject was.
    def blue_exhausted
      shares = @frames.map do |image|
        floored = image - (0..2).map { |c| (image[c] * 255.0).cast(:uchar).percent(1) / 255.0 }
        linear = Colour.to_linear(Colour.clamp01(floored))
        y = (linear * LUMA).bandmean * 3.0
        green = (linear[1] < 1e-5).ifthenelse(1e-5, linear[1])
        gone = (y > 0.12) & (linear[2] < green * 0.125)
        gone.avg / 255.0
      end
      finding(:blue_exhausted, Measurements.percentile(shares.sort, 50))
    end

    # A channel whose darkest percent sits at black while another channel's
    # sits well above it. Lifting the shadows cannot bring that channel back,
    # only brighten what the others hold.
    def crushed_channel
      floors = @frames.map do |image|
        (0..2).map { |c| (image[c] * 255.0).cast(:uchar).percent(1).to_f }
      end
      median = (0..2).map { |c| Measurements.percentile(floors.map { |f| f[c] }.sort, 50) }
      low = median.each_with_index.min_by(&:first)
      gap = median.max - low[0]
      severity = low[0] <= 3 ? gap : 0.0
      finding(:crushed_channel, severity, "#{%w[red green blue][low[1]]} at #{low[0].round}, others up to #{median.max.round}")
    end

    def clipped
      shares = @frames.map do |image|
        top = (image[0] > image[1]).ifthenelse(image[0], image[1])
        top = (top > image[2]).ifthenelse(top, image[2])
        (top >= 254.0 / 255.0).avg / 255.0
      end
      finding(:clipped, Measurements.percentile(shares.sort, 50))
    end

    def grain
      levels = @grains
      return nil if levels.empty?

      finding(:grain, Measurements.percentile(levels.sort, 50) / Pipeline::USUAL_GRAIN)
    end

    # How far apart the three channels' corner falloff sits, which is the tint
    # the corner lift would paint. Present on Superia too, where blue skies in
    # the top corners read as corners that lose red, so it is a warning about
    # the stage rather than about the scan.
    def corner_tint(flat)
      return nil unless flat && !flat.flat?

      stops = flat.corners.map { |value| Math.log2(1.0 / value) }
      finding(:corner_tint, stops.max - stops.min,
              format("red %.2f, green %.2f, blue %.2f stops down", *stops))
    end
  end
end
