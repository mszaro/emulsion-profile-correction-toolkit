require "yaml"

module Emulsion
  # How a film scanned with the right profile renders neutral surfaces at each
  # tone, and where its tones fall. A film the scanner got wrong is balanced
  # toward one of these, loaded by name from references/ or from a file
  # written by tools/measure_reference.rb.
  class Reference
    DIR = File.expand_path("../../references", __dir__)

    attr_reader :id, :name, :neutral, :tone_shape, :healthy_spread

    def self.available
      Dir.glob(File.join(DIR, "*.yml")).map { |f| File.basename(f, ".yml") }.sort
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
  end
end
