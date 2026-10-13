require "yaml"
require "json"

module FilmScan
  # How a film scanned with the right profile renders neutral surfaces at each
  # tone, and where its tones fall. A film the scanner got wrong is balanced
  # toward one of these, loaded by name from references/ or from a file
  # written by tools/measure_reference.rb.
  class Reference
    DIR = File.expand_path("../../references", __dir__)

    attr_reader :id, :name, :neutral, :tone_shape, :healthy_spread

    # Each roll gets an equal say in the neutral, whatever its length.
    PER_ROLL = 60_000

    def self.available
      Dir.glob(File.join(DIR, "*.yml")).map { |f| File.basename(f, ".yml") }.sort
    end

    # Measured from well scanned rolls, given as lists of paths keyed by the
    # roll's name. Sampled inside the picture, since the scanner's borders are
    # not part of any scene.
    def self.measure(rolls, id:, name:, verbose: true)
      pixels = []
      shapes = []
      spreads = []
      rolls.each do |roll, paths|
        raise ArgumentError, "no images in #{roll}" if paths.empty?

        puts roll if verbose
        sample = RollSample.collect(paths, verbose: verbose) { |image| FrameEdges.detect(image).picture }
        offsets = ColourBalance.black_offsets(sample)
        linear = ColourBalance.linear_pixels(sample, offsets)
        pixels.concat(linear.each_slice([linear.size / PER_ROLL, 1].max).map(&:first))
        shapes << ToneCurve.shape_of(sample)
        # How widely a well scanned roll spreads its colour, so the gamut fit
        # knows what healthy looks like on the film it is aiming at.
        spreads << GamutFit.spread_of(sample)
      end

      # A well-scanned film has no large cast to find first, so each band is
      # read from the greys nearest neutral rather than from whatever fills it.
      zero = Array.new(ColourBalance::TONES.size) { [0.0, 0.0] }
      neutral = ColourBalance.neutral_by_tone(pixels, from: zero)
      raise ArgumentError, "too few pixels to measure a neutral" if neutral.compact.size < 2

      new(id, name: name, tones: ColourBalance::TONES, neutral: ColourBalance.fill_gaps(neutral),
              tone_shape: shapes.transpose.map { |values| Measurements.percentile(values.sort, 50) },
              healthy_spread: Measurements.percentile(spreads.sort, 50))
    end

    def self.load(name)
      is_path = name.end_with?(".yml", ".yaml") || name.include?("/")
      path = is_path ? File.expand_path(name) : File.join(DIR, "#{name}.yml")
      unless File.file?(path)
        raise ArgumentError, "no reference called #{name}. Available: #{available.join(', ')}"
      end

      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false,
                                             symbolize_names: true)
      new(File.basename(path, ".*"), data)
    rescue Psych::Exception => e
      raise ArgumentError, "could not read reference #{path}: #{e.message}"
    end

    def initialize(id, data)
      raise ArgumentError, "reference #{id} should be a list of settings" unless data.is_a?(Hash)
      # Neutral is only comparable band for band, so the bands must be the ones
      # ColourBalance measures.
      unless data[:tones] == ColourBalance::TONES
        raise ArgumentError, "reference #{id} was measured on other tone bands; measure it again"
      end
      neutral = data[:neutral]
      unless neutral.is_a?(Array) && neutral.size == ColourBalance::TONES.size &&
             neutral.all? { |pair| pair.is_a?(Array) && pair.size == 2 && pair.all?(Numeric) }
        raise ArgumentError, "reference #{id} needs a [red, blue] neutral for each tone"
      end
      shape = data[:tone_shape]
      unless shape.nil? || (shape.is_a?(Array) && shape.size == ToneCurve::QUANTILES.size &&
                            shape.all?(Numeric))
        raise ArgumentError, "reference #{id} needs a tone shape value for each of " \
                             "#{ToneCurve::QUANTILES.join(', ')} percent"
      end

      spread = data[:healthy_spread]
      unless spread.nil? || (spread.is_a?(Numeric) && spread.between?(0.0, 1.0))
        raise ArgumentError, "reference #{id} needs healthy_spread between 0 and 1"
      end

      @id = id
      @name = data[:name] || id
      @neutral = neutral
      @tone_shape = shape
      @healthy_spread = spread
    end

    # As references/ keeps it, with a comment saying where it came from.
    def to_yaml(comment)
      <<~YAML
        # #{comment.lines.map(&:chomp).join("\n# ")}
        name: #{name.to_json}

        # Neutral is [red, blue] in stops relative to green, at each tone band.
        tones: [#{ColourBalance::TONES.join(', ')}]
        neutral:
        #{neutral.map { |r, b| format('  - [%.3f, %.3f]', r, b) }.join("\n")}

        # Where a typical frame's luma falls, at #{ToneCurve::QUANTILES.join(', ')} percent,
        # once stretched between its #{ToneCurve::BLACK} and #{ToneCurve::WHITE} percentiles.
        tone_shape: [#{tone_shape.map { |v| format('%.3f', v) }.join(', ')}]

        # How widely a typical roll spreads its colour across hues, the median of
        # the rolls above. The gamut fit reopens a film toward this and no further.
        healthy_spread: #{format('%.3f', healthy_spread)}
      YAML
    end
  end
end
