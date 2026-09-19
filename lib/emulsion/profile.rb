require "yaml"

module Emulsion
  # Everything the toolkit knows about one film stock: the settings that shape
  # the picture, tuned for how that film's scans go wrong. Loaded by name from
  # profiles/, or from any YAML file with the same keys.
  class Profile
    DIR = File.expand_path("../../profiles", __dir__)

    REQUIRED = %i[black white neutral wb wb_clamp shadow_wb target_saturation
                  max_vibrance knee max_stretch contrast chroma healthy_spread].freeze
    OPTIONAL = %i[name saturation chroma_radius roll_fit reference roll_balance
                  roll_balance_limit film_gains frame_balance frame_balance_limit
                  roll_tone].freeze

    attr_reader :id, :name, :settings, :healthy_spread

    def self.available
      Dir.glob(File.join(DIR, "*.yml")).map { |f| File.basename(f, ".yml") }.sort
    end

    # A bare name is looked up in profiles/. Anything that looks like a path
    # is read as a file, so a new film can be tried without touching the repo.
    def self.load(name)
      is_path = name.end_with?(".yml", ".yaml") || name.include?("/")
      path = is_path ? File.expand_path(name) : File.join(DIR, "#{name}.yml")
      unless File.file?(path)
        raise ArgumentError, "no profile called #{name}. Available: #{available.join(', ')}"
      end

      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false,
                                             symbolize_names: true)
      new(File.basename(path, ".*"), data)
    rescue Psych::Exception => e
      raise ArgumentError, "could not read profile #{path}: #{e.message}"
    end

    def initialize(id, data)
      raise ArgumentError, "profile #{id} should be a list of settings" unless data.is_a?(Hash)

      unknown = data.keys - REQUIRED - OPTIONAL
      raise ArgumentError, "profile #{id} has unknown settings: #{unknown.join(', ')}" if unknown.any?

      missing = REQUIRED - data.keys
      raise ArgumentError, "profile #{id} is missing: #{missing.join(', ')}" if missing.any?

      gains = data[:film_gains]
      unless gains.nil? || (gains.is_a?(Array) && gains.size == ColourBalance::TONES.size &&
                            gains.all? { |g| g.is_a?(Array) && g.size == 3 && g.all?(Numeric) })
        raise ArgumentError, "profile #{id} needs film_gains as [red, green, blue] for each of " \
                             "#{ColourBalance::TONES.size} tones; tools/measure_film.rb writes them"
      end

      @id = id
      @name = data[:name] || id
      @healthy_spread = data[:healthy_spread]
      @settings = data.except(:name, :healthy_spread)
    end
  end
end
