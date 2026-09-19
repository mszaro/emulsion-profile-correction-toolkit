require "yaml"
require "digest"

module Emulsion
  # Remembers a roll's fits, kept next to the output as roll-fit.yml.
  #
  # The key covers everything the fits depend on: each source file's path, size
  # and time, the settings and reference the fits were made against, and a
  # digest of the fitting code, so changing how a fit works never quietly
  # serves an old answer.
  module AnalysisCache
    module_function

    VERSION = 4

    SOURCES = %w[gamut_fit.rb roll_sample.rb colour_balance.rb tone_curve.rb].freeze

    # Inputs is a hash of whatever else the fits were made from.
    def key(paths, inputs)
      files = paths.sort.map do |p|
        stat = File.stat(p)
        "#{p}:#{stat.size}:#{stat.mtime.to_i}"
      end
      code = SOURCES.map do |name|
        Digest::SHA256.file(File.join(__dir__, name)).hexdigest
      end
      Digest::SHA256.hexdigest([VERSION, inputs.sort.inspect, *code, *files].join("\n"))
    end

    def path(destination)
      File.join(destination, "roll-fit.yml")
    end

    def load(destination, key)
      file = path(destination)
      return nil unless File.exist?(file)

      data = YAML.safe_load(File.read(file), permitted_classes: [], aliases: false,
                                               symbolize_names: true)
      return nil unless data.is_a?(Hash) && data[:key] == key

      data
    rescue Psych::Exception, SystemCallError
      nil
    end

    # The stored fits are raw, before their strengths scale them, so changing
    # a strength reuses them. Any fit may be absent.
    def save(destination, key, fit: nil, balance: nil, tone: nil)
      data = { "key" => key }
      data["balance"] = balance.to_h if balance
      data["tone"] = tone.to_h if tone
      if fit
        data["fit"] = {
          "gains" => fit.gains,
          "clipped" => fit.clipped,
          "spread_before" => fit.spread_before,
          "spread_after" => fit.spread_after
        }
      end
      File.write(path(destination), YAML.dump(data))
    rescue SystemCallError
      # A cache that cannot be written is not worth failing a render over.
      nil
    end
  end
end
