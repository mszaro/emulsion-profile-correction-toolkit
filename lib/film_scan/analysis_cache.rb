require "yaml"
require "digest"
require "fileutils"

module FilmScan
  # Remembers a roll's fits, kept next to the output as roll-fit.yml and again
  # under the user's cache folder by key, so the same roll rendered into
  # another folder finds them too.
  #
  # The key covers everything the fits depend on: each source file's path, size
  # and time, the settings and reference the fits were made against, and a
  # digest of the toolkit's code, since the tuning renders frames through all
  # of it, so changing how a fit works never quietly serves an old answer.
  module AnalysisCache
    module_function

    VERSION = 4

    # Inputs is a hash of whatever else the fits were made from.
    def key(paths, inputs)
      files = paths.sort.map do |p|
        stat = File.stat(p)
        "#{p}:#{stat.size}:#{stat.mtime.to_i}"
      end
      code = Dir[File.join(__dir__, "*.rb")].sort.map { |file| Digest::SHA256.file(file).hexdigest }
      Digest::SHA256.hexdigest([VERSION, inputs.sort.inspect, *code, *files].join("\n"))
    end

    def path(destination)
      File.join(destination, "roll-fit.yml")
    end

    # Under XDG_CACHE_HOME where it is set, and ~/.cache otherwise. Nil when
    # there is no home to keep it in.
    def shared_path(key)
      base = ENV["XDG_CACHE_HOME"].to_s
      base = File.join(Dir.home, ".cache") if base.empty?
      File.join(base, "film_scan", "roll-fits", "#{key}.yml")
    rescue ArgumentError
      nil
    end

    # The fits for this key, from the output folder or else from the shared
    # copy, which is then copied next to the output as if measured for it.
    def load(destination, key)
      data = read(path(destination), key)
      return data if data

      shared = shared_path(key)
      data = read(shared, key)
      write(path(destination), File.read(shared)) if data
      data
    rescue SystemCallError
      data
    end

    def read(file, key)
      return nil unless file && File.exist?(file)

      data = YAML.safe_load(File.read(file), permitted_classes: [], aliases: false,
                                               symbolize_names: true)
      return nil unless data.is_a?(Hash) && data[:key] == key

      data
    rescue Psych::Exception, SystemCallError
      nil
    end

    # The stored fits are raw, before their strengths scale them, so changing
    # a strength reuses them. Any fit may be absent.
    def save(destination, key, fit: nil, balance: nil, tone: nil, flat: nil, tilt: nil)
      data = { "key" => key }
      data["balance"] = balance.to_h if balance
      data["tone"] = tone.to_h if tone
      data["flat"] = flat.to_h if flat
      data["tilt"] = tilt if tilt
      if fit
        data["fit"] = {
          "gains" => fit.gains,
          "clipped" => fit.clipped,
          "spread_before" => fit.spread_before,
          "spread_after" => fit.spread_after
        }
      end
      text = YAML.dump(data)
      write(path(destination), text)
      write(shared_path(key), text)
    end

    # Written under a temporary name and renamed, so a run beside this one
    # never reads half a file.
    def write(file, text)
      return nil unless file

      FileUtils.mkdir_p(File.dirname(file))
      partial = "#{file}.#{Process.pid}.partial"
      File.write(partial, text)
      File.rename(partial, file)
    rescue SystemCallError
      # A cache that cannot be written is not worth failing a render over.
      File.delete(partial) if partial && File.exist?(partial)
      nil
    end
  end
end
