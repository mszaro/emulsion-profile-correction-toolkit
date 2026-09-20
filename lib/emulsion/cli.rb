require "optparse"
require "fileutils"
require "yaml"

module Emulsion
  # Command line front end. Corrects every scan in a folder and writes the
  # results to a sibling folder, leaving the originals untouched.
  class CLI
    EXTENSIONS = %w[tif tiff TIF TIFF jpg jpeg JPG JPEG png PNG].freeze

    def self.run(argv)
      new.run(argv)
    end

    # What --fix was asked for: the usual set, everything, or a named list.
    def self.fixes_from(names)
      return DEFAULT_FIXES if names.nil? || names.empty?
      return FIXES if names.map(&:to_s).include?("all")

      chosen = names.map { |name| name.to_s.strip.downcase.to_sym }
      unknown = chosen - FIXES
      raise ArgumentError, "no such fix: #{unknown.join(', ')}. Try #{FIXES.join(', ')} or all" if unknown.any?

      chosen
    end

    def run(argv)
      flags = { previews: false }
      parser = build_parser(flags)
      parser.parse!(argv)

      source = argv.shift
      unless source
        warn parser
        return 1
      end
      unless flags[:profile]
        warn "which film is this? Pass --profile, one of: #{Profile.available.join(', ')}"
        return 1
      end

      begin
        profile = Profile.load(flags[:profile])
      rescue ArgumentError => e
        warn e.message
        return 1
      end
      # The profile sets the picture, and anything given on the command line wins.
      options = DEFAULTS.merge(profile.settings).merge(flags)

      begin
        reference = options[:reference] && Reference.load(options[:reference])
      rescue ArgumentError => e
        warn e.message
        return 1
      end

      source = File.expand_path(source)
      unless File.directory?(source)
        warn "not a directory: #{source}"
        return 1
      end

      destination = options[:out] ? File.expand_path(options[:out])
                                  : "#{source.chomp('/')} - corrected"
      if destination == source
        warn "refusing to write into the source directory"
        return 1
      end

      files = find_files(source, options[:only])
      if files.empty?
        warn "no images matching #{options[:only] || '*'} in #{source}"
        return 1
      end

      FileUtils.mkdir_p(destination)
      preview_dir = File.join(destination, "preview")
      FileUtils.mkdir_p(preview_dir) if options[:previews]

      overrides = load_overrides(options[:overrides])
      puts "profile: #{profile.name}"

      fits = analyse_roll(source, destination, profile, reference, options)

      puts "processing #{files.size} frames -> #{destination}"
      files.each_with_index do |path, i|
        name = File.basename(path)
        stem = File.basename(name, ".*")
        frame_options = options.merge(overrides[stem] || {})
        result = Pipeline.new(frame_options, reference: reference, **fits).call(path)
        # Render once into memory when a preview is wanted too. Shrinking the
        # unrendered pipeline for the preview ran all of it again, and on a
        # 6144px frame that took 45GB.
        result = result.copy_memory if options[:previews]
        written = write_result(result, destination, stem, path, options)
        if options[:previews]
          jpeg = File.join(preview_dir, "#{stem}.jpg")
          (result * 255).cast(:uchar).thumbnail_image(1600, size: :down)
                        .jpegsave(jpeg, Q: 92)
        end
        puts "  [#{i + 1}/#{files.size}] #{name} -> #{File.basename(written)}"
      end

      File.write(File.join(destination, "settings.yml"),
                 YAML.dump(options.transform_keys(&:to_s)))
      puts "done"
      0
    end

    private

    # The roll is fitted once, across every frame, before any frame is written:
    # first the colour balance toward the reference, then the tone curve and
    # the gamut fit, which both see the roll as balanced. Returns the fits
    # wanted, as the keywords Pipeline takes.
    def analyse_roll(source, destination, profile, reference, options)
      want = {
        balance: reference && options[:roll_balance].positive?,
        tone: reference&.tone_shape && options[:roll_tone].positive?,
        fit: options[:roll_fit].positive?,
        flat: options[:fix].include?(:flat)
      }
      return {} unless want.values.any?

      all = find_files(source, nil)
      key = AnalysisCache.key(all, healthy_spread: profile.healthy_spread,
                                   neutral: want[:balance] && reference.neutral,
                                   film_gains: want[:balance] && options[:film_gains],
                                   roll_balance_limit: want[:balance] && options[:roll_balance_limit],
                                   tone_shape: want[:tone] && reference.tone_shape,
                                   roll_balance: want[:balance] && options[:roll_balance],
                                   fix: options[:fix].sort)
      cached = AnalysisCache.load(destination, key) || {}
      fits = {}
      fits[:balance] = ColourBalance.from_cache(cached[:balance]) if want[:balance] && cached[:balance]
      fits[:tone] = ToneCurve.from_cache(cached[:tone]) if want[:tone] && cached[:tone]
      fits[:fit] = GamutFit.from_cache(cached[:fit]) if want[:fit] && cached[:fit]
      fits[:flat] = FlatField.from_cache(cached[:flat]) if want[:flat] && cached[:flat]

      if want.any? { |name, wanted| wanted && !fits[name] }
        if want[:flat] && !fits[:flat]
          puts "measuring the falloff in the corners..."
          fits[:flat] = FlatField.fit(all) { |_path, image| FrameEdges.detect(image).picture }
        end
        puts "sampling roll of #{all.size} frames..."
        # Sampled inside the picture when the borders are coming off anyway,
        # since overscan and rebate are not part of any scene.
        sample = if options[:fix].include?(:crop)
                   RollSample.collect(all) { |image| FrameEdges.detect(image).picture }
                 else
                   RollSample.collect(all)
                 end
        if want[:balance] && !fits[:balance]
          puts "balancing the roll toward #{reference.name}..."
          fits[:balance] = ColourBalance.fit_roll(sample, reference.neutral, film: options[:film_gains],
                                                                             limit: options[:roll_balance_limit])
        end
        if fits[:balance]
          fits[:balance].strength = options[:roll_balance]
          sample = fits[:balance].apply_to_sample(sample)
        end
        fits[:tone] ||= ToneCurve.fit(sample, reference.tone_shape) if want[:tone]
        if want[:fit] && !fits[:fit]
          puts "fitting colour to reopen the roll's gamut..."
          fits[:fit] = GamutFit.new(sample, healthy_spread: profile.healthy_spread)
        end
        tune_balance(all, options, fits, reference) if fits[:balance]
        AnalysisCache.save(destination, key, **fits)
      else
        puts "reusing the roll analysis"
      end

      { balance: :roll_balance, tone: :roll_tone, fit: :roll_fit, flat: :flat_field }.each do |name, setting|
        next unless fits[name]

        fits[name].strength = options[setting]
        puts fits[name].report
      end
      fits
    end

    # Frames checked through the whole pipeline when tuning the balance, how
    # many times, how far the tuning may move the colour in stops, and how
    # much of each round's measurement it takes, since the tone work multiplies
    # a correction made this early.
    TUNE_FRAMES = 8
    TUNE_ROUNDS = 2
    TUNE_LIMIT = 0.6
    TUNE_DAMPING = 0.6

    # Wide enough that the film border is still found here. At 640 a rebate is
    # a few pixels across and goes unseen, so the tuning would measure frames
    # that still had the scanner's white overscan in them and pull the whole
    # roll's balance toward correcting for it.
    TUNE_WIDTH = 1500

    # The endpoint stretch and the tone work multiply whatever tint is left in
    # a frame, so a balance that lands on the reference before them lands warm
    # after them. This renders a few frames small, measures the greys in the
    # finished picture, and nudges the roll's balance until they land right.
    def tune_balance(paths, options, fits, reference)
      step = [paths.size / TUNE_FRAMES, 1].max
      frames = paths.each_slice(step).map(&:first).first(TUNE_FRAMES).map do |path|
        # Into memory, since a thumbnail is read once through and the pipeline
        # goes over a frame several times.
        image = Vips::Image.thumbnail(path, TUNE_WIDTH, size: :down).copy_memory
        image = image[0..2] if image.bands > 3
        image.cast(:float) / (image.format == :ushort ? 65535.0 : 255.0)
      end
      TUNE_ROUNDS.times do
        rendered = frames.map { |image| Pipeline.new(options, reference: reference, **fits).render(image) }
        pixels = rendered.flat_map { |image| ColourBalance.frame_pixels(image) }
        drift = ColourBalance.residual_gains(pixels, reference.neutral, TUNE_LIMIT,
                                             ColourBalance::FRAME_MIN_PIXELS)
        break unless drift

        gains = fits[:balance].gains.zip(drift).map do |before, delta|
          before.zip(delta).map { |a, b| a + b * TUNE_DAMPING }
        end
        fits[:balance] = ColourBalance.new(fits[:balance].offsets, gains)
        fits[:balance].strength = options[:roll_balance]
      end
    end

    FORMATS = {
      "tiff" => ".tiff", "tif" => ".tiff",
      "jpeg" => ".jpg", "jpg" => ".jpg",
      "png" => ".png",
      "heic" => ".heic", "heif" => ".heic",
      "jp2" => ".jp2", "jpeg2000" => ".jp2"
    }.freeze

    # What each format can hold, and what it gets when nothing is asked for.
    # A correction stretches levels a long way, so depth is worth having where
    # a format carries it well. HEIC is the exception: its deeper modes here
    # measure 39.5 dB at 12 bits against 50.1 dB at 8, so the encoder is
    # mangling them and 8 is what it gets unless --bits says otherwise.
    DEPTHS = {
      "tiff" => [8, 16], "png" => [8, 16], "jp2" => [8, 16],
      "heic" => [8, 10, 12], "jpeg" => [8]
    }.freeze
    NATURAL_DEPTH = { "tiff" => 16, "png" => 16, "jp2" => 16, "heic" => 8, "jpeg" => 8 }.freeze

    # Rounding a stretched frame down to 8 bits can band a clear sky, so a
    # little noise goes in first and the step becomes grain instead.
    DITHER = 0.4

    # Match the input unless told otherwise, so a JPEG scan comes back a JPEG.
    def output_format(source_path, options)
      return FORMATS.key?(options[:format]) ? canonical(options[:format]) : options[:format] if options[:format]

      case File.extname(source_path).downcase
      when ".jpg", ".jpeg" then "jpeg"
      when ".png" then "png"
      when ".heic", ".heif" then "heic"
      when ".jp2", ".jpf", ".j2k" then "jp2"
      else "tiff"
      end
    end

    # tif and jpg and jpeg2000 all name formats this already knows.
    def canonical(format)
      { "tif" => "tiff", "jpg" => "jpeg", "heif" => "heic", "jpeg2000" => "jp2" }.fetch(format, format)
    end

    def depth_for(format, bits)
      offered = DEPTHS.fetch(format, [8])
      return NATURAL_DEPTH.fetch(format, 8) unless bits

      offered.select { |d| d <= bits }.max || offered.min
    end

    # Written under a temporary name and renamed when complete, so an
    # interrupted run never leaves a truncated file that looks finished.
    def write_result(result, destination, stem, source_path, options)
      format = output_format(source_path, options)
      path = File.join(destination, stem + FORMATS.fetch(format))
      partial = "#{path}.partial"
      save(result, partial, format, options)
      File.rename(partial, path)
      path
    ensure
      File.delete(partial) if partial && File.exist?(partial)
    end

    def save(result, partial, format, options)
      bits = depth_for(format, options[:bits])
      quality = options[:quality]
      case format
      # Chroma subsampling smears grain into coloured blocks, so it stays off
      # wherever a format would otherwise apply it.
      when "jpeg"
        quantise(result, 8).jpegsave(partial, Q: quality, subsample_mode: :off,
                                              optimize_coding: true)
      when "heic"
        quantise(result, bits).heifsave(partial, Q: quality, bitdepth: bits, lossless: quality >= 100,
                                                 compression: :hevc, subsample_mode: :off)
      when "jp2"
        quantise(result, bits).jp2ksave(partial, Q: quality, lossless: quality >= 100,
                                                 subsample_mode: :off)
      when "png"
        quantise(result, bits).pngsave(partial, compression: 6)
      else
        quantise(result, bits).tiffsave(partial, compression: :deflate, predictor: :horizontal)
      end
    end

    # A float frame in 0..1 as whole numbers at the depth asked for.
    def quantise(result, bits)
      top = (1 << bits) - 1
      scaled = result * top
      # Deeper than 8 bits has steps too fine to see, so only 8 needs the noise.
      scaled += Vips::Image.gaussnoise(result.width, result.height, mean: 0.0, sigma: DITHER) if bits == 8
      scaled = (scaled < 0).ifthenelse(0, (scaled > top).ifthenelse(top, scaled))
      scaled.cast(bits > 8 ? :ushort : :uchar)
    end

    # Per-frame overrides, keyed by filename without extension. Values use the
    # long option names, so "saturation: 1.6" under "000057".
    def load_overrides(path)
      return {} unless path
      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      raise "overrides file must be a mapping of frame name to settings" unless raw.is_a?(Hash)
      raw.each_with_object({}) do |(frame, settings), acc|
        acc[frame.to_s] = settings.transform_keys { |k| k.to_s.tr("-", "_").to_sym }
      end
    end

    def find_files(source, only)
      pattern = only || "*"
      EXTENSIONS.flat_map { |ext| Dir.glob(File.join(source, "#{pattern}.#{ext}")) }
                .uniq.sort
    end

    def build_parser(options)
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Correct lab scans of film stocks the scanner had no profile for.

          Usage: emulsion --profile NAME [options] SOURCE_DIR

          Writes corrected frames to "SOURCE_DIR - corrected", in the same format
          they came in as. Originals are never modified. The profile sets the
          colour, tone and grain settings below; any you pass override it.
        BANNER

        opts.separator ""
        opts.on("-p", "--profile NAME",
                "Film stock: #{Profile.available.join(', ')},",
                "or the path to a profile YAML file of your own.") { |v| options[:profile] = v }

        opts.separator ""
        opts.separator "Colour:"
        opts.on("--target-saturation FLOAT", Float,
                "Boost each frame toward this mean saturation.") { |v| options[:target_saturation] = v }
        opts.on("-S", "--saturation FLOAT", Float,
                "Fixed vibrance for every frame instead of a target.") { |v| options[:saturation] = v }
        opts.on("--max-vibrance FLOAT", Float,
                "Ceiling on the vibrance boost.") { |v| options[:max_vibrance] = v }
        opts.on("--knee FLOAT", Float,
                "Chroma at which the boost halves. Lower protects colourful subjects.") { |v| options[:knee] = v }
        opts.on("--reference NAME",
                "Film to balance the roll toward: #{Reference.available.join(', ')},",
                "or a file from tools/measure_reference.rb.") { |v| options[:reference] = v }
        opts.on("--roll-balance FLOAT", Float,
                "Strength of the balance toward the reference, 0 to 1",
                "(default #{DEFAULTS[:roll_balance]}). Only with a reference.") { |v| options[:roll_balance] = v }
        opts.on("--roll-balance-limit STOPS", Float,
                "How far a roll may drift from its film's measured cast, easing",
                "off toward this many stops (default #{DEFAULTS[:roll_balance_limit]}).") { |v| options[:roll_balance_limit] = v }
        opts.on("--frame-balance FLOAT", Float,
                "Strength of each frame's own balance toward the reference,",
                "after the roll's, 0 to 1. Only with a reference.") { |v| options[:frame_balance] = v }
        opts.on("--frame-balance-limit STOPS", Float,
                "How far the frame balance may move a frame, easing off",
                "toward this many stops (default #{DEFAULTS[:frame_balance_limit]}).") { |v| options[:frame_balance_limit] = v }
        opts.on("--roll-tone FLOAT", Float,
                "Strength of the roll's tone curve toward the reference's",
                "tones, 0 to 1. Only with a reference.") { |v| options[:roll_tone] = v }
        opts.on("--roll-fit FLOAT", Float,
                "Strength of the whole-roll colour fit, 0 to 1 (default #{DEFAULTS[:roll_fit]}).",
                "A roll that is already healthy fits to no change.") { |v| options[:roll_fit] = v }
        opts.on("-w", "--wb FLOAT", Float,
                "Per-frame white balance strength, 0 to 1. 0 disables it.") { |v| options[:wb] = v }
        opts.on("--wb-clamp FLOAT", Float,
                "Cap on any single channel gain.") { |v| options[:wb_clamp] = v }
        opts.on("--shadow-wb FLOAT", Float,
                "Strength of the separate shadow balance.") { |v| options[:shadow_wb] = v }
        opts.on("-n", "--neutral FLOAT", Float,
                "Grey-world share, 0 to 1. Usually best left at 0.") { |v| options[:neutral] = v }

        opts.separator ""
        opts.separator "Tone:"
        opts.on("-t", "--contrast FLOAT", Float, "S-curve amount.") { |v| options[:contrast] = v }
        opts.on("--black FLOAT", Float, "Black clip percentile.") { |v| options[:black] = v }
        opts.on("--white FLOAT", Float, "White clip percentile.") { |v| options[:white] = v }
        opts.on("--max-stretch FLOAT", Float,
                "Most a frame's range may be stretched, so a very flat",
                "frame can stay a little flat rather than magnify grain.") { |v| options[:max_stretch] = v }

        opts.separator ""
        opts.separator "Grain:"
        opts.on("-c", "--chroma FLOAT", Float,
                "Colour noise reduction, 0 to 1. Luma grain is left alone.") { |v| options[:chroma] = v }
        opts.on("-R", "--chroma-radius INT", Integer,
                "Colour blur radius in pixels. Scales with image width by default.") { |v| options[:chroma_radius] = v }

        opts.separator ""
        opts.separator "Beyond the film:"
        opts.on("--fix [LIST]", Array,
                "Corrections that are about the camera, the scanner or the",
                "frame rather than the film, off unless asked for. Bare --fix",
                "turns on the usual set, --fix all turns on everything, or",
                "name them: #{FIXES.join(', ')}.") { |v| options[:fix] = CLI.fixes_from(v) }
        opts.on("--flat-field FLOAT", Float,
                "Strength of the lift in the corners, 0 to 1",
                "(default #{DEFAULTS[:flat_field]}).") { |v| options[:flat_field] = v }
        opts.on("--recovery FLOAT", Float,
                "Strength of the shadow and highlight recovery, 0 to 1",
                "(default #{DEFAULTS[:recovery]}).") { |v| options[:recovery] = v }
        opts.on("--lost-colour FLOAT", Float,
                "Ease toward grey where a channel has nothing left to say,",
                "0 to 1 (default #{DEFAULTS[:lost_colour]}). For films whose blue dies",
                "on warm subjects, where how warm they were cannot be known.") { |v| options[:lost_colour] = v }
        opts.on("--chroma-shape FLOAT", Float,
                "Bend the film's colour onto the reference's shape, 0 to 1",
                "(default #{DEFAULTS[:chroma_shape]}). Needs chroma_map in the profile,",
                "written by tools/measure_shape.rb.") { |v| options[:chroma_shape] = v }
        opts.on("--sharpness FLOAT", Float,
                "Strength of the sharpening, 0 to 1 (default #{DEFAULTS[:sharpness]}).",
                "Frames measured as soft are sharpened; the rest are left.") { |v| options[:sharpness] = v }

        opts.separator ""
        opts.separator "Output:"
        opts.on("-o", "--out DIR", "Destination directory.") { |v| options[:out] = v }
        opts.on("-f", "--format FORMAT", FORMATS.keys,
                "Output format: tiff, jpeg, png, heic or jp2.",
                "Defaults to the input's.") { |v| options[:format] = v }
        opts.on("--bits N", Integer,
                "Bits per channel where the format allows it: 8 or 16.",
                "TIFF, PNG and JPEG 2000 take 16 by default, HEIC and JPEG 8.",
                "Eight bit output is dithered, so a stretched sky keeps its",
                "gradient instead of banding.") { |v| options[:bits] = v }
        opts.on("--quality N", Integer,
                "Quality for the lossy formats (default #{DEFAULTS[:quality]}).",
                "100 asks HEIC and JPEG 2000 for lossless, which on HEIC is",
                "the only step up: its encoder gives the same file at 95 and",
                "at 100. Always 4:4:4.") { |v| options[:quality] = v }
        opts.on("--previews", "--jpeg", "Also write 1600px preview JPEGs.") { |v| options[:previews] = v }
        opts.on("--only GLOB", "Filter frames, for example '0000[45]*'.") { |v| options[:only] = v }
        opts.on("--overrides FILE", "YAML of per-frame settings, keyed by filename",
                "without extension.") { |v| options[:overrides] = v }

        opts.separator ""
        opts.on("-h", "--help", "Show this message.") do
          puts opts
          exit 0
        end
        opts.on("-v", "--version", "Show version.") do
          puts Emulsion::VERSION
          exit 0
        end
      end
    end
  end
end
