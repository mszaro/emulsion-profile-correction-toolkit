require "optparse"
require "fileutils"
require "yaml"
require "etc"
require "open3"

module FilmScan
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
      raise ArgumentError, "borders come off with --crop now, not --fix crop" if unknown.include?(:crop)
      raise ArgumentError, "no such fix: #{unknown.join(', ')}. Try #{FIXES.join(', ')} or all" if unknown.any?

      chosen
    end

    # A bare --fix just before the folder would take the folder for its list,
    # so the word after it only counts as a list when it names fixes.
    def self.bare_fix(argv)
      argv.each_with_index.map do |arg, i|
        following = argv[i + 1]
        names = following.to_s.downcase.split(",")
        listed = !names.empty? && names.all? { |name| name == "all" || FIXES.include?(name.to_sym) }
        arg == "--fix" && !listed ? "--fix=#{DEFAULT_FIXES.join(",")}" : arg
      end
    end

    def run(argv)
      flags = { previews: false }
      parser = build_parser(flags)
      argv.replace(CLI.bare_fix(argv))
      parser.parse!(argv)
      share_the_machine(flags)

      source = argv.shift
      unless source
        warn parser
        return 1
      end
      convert = flags[:convert_only]
      unless flags[:profile] || convert || flags[:orient]
        warn "which film is this? Pass --profile, one of: #{Profile.available.join(', ')}"
        return 1
      end

      begin
        profile = convert || flags[:orient] ? nil : Profile.load(flags[:profile])
      rescue ArgumentError => e
        warn e.message
        return 1
      end
      # The profile sets the picture, and anything given on the command line wins.
      options = DEFAULTS.merge(profile ? profile.settings : {}).merge(flags)
      if options[:encoder] == "apple" && (reason = AppleHeic.unavailable_reason)
        warn reason
        return 1
      end
      options[:engine] ||= Metal.default_engine
      if options[:engine] == "apple" && (reason = Metal.unavailable_reason)
        warn reason
        return 1
      end

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

      begin
        return orient(source, files, destination, options) if options[:orient]
      rescue ArgumentError => e
        warn e.message
        return 1
      end

      begin
        reference = matched_reference(options[:match], destination) if options[:match] && !convert
      rescue ArgumentError => e
        warn e.message
        return 1
      end

      return explain(source, reference, options) if options[:explain] || options[:audit]

      FileUtils.mkdir_p(destination)
      preview_dir = File.join(destination, "preview")
      FileUtils.mkdir_p(preview_dir) if options[:previews]

      overrides = load_overrides(options[:overrides])
      Orientation.overrides = orientations(find_files(source, nil), overrides)
      sheet = options[:contact_sheet] ? ContactSheet.new(File.basename(source)) : nil
      puts(convert ? "converting only, no correction" : "profile: #{profile.name}")

      unless convert
        options = measure_frame_balance(source, reference, options)
        fits = analyse_roll(source, destination, profile, reference, options)
      end

      puts "processing #{files.size} frames -> #{destination}"
      writing = nil
      files.each_with_index do |path, i|
        name = File.basename(path)
        stem = File.basename(name, ".*")
        frame_options = options.merge(overrides[stem] || {})
        result = convert ? converted(path, options) : Pipeline.new(frame_options, reference: reference, **fits).call(path)
        # Render once into memory when a preview or the contact sheet wants the
        # frame too. Shrinking the unrendered pipeline for either ran all of it
        # again, and on a 6144px frame that took 45GB.
        result = result.copy_memory if options[:previews] || sheet
        # heif-enc works on one frame while the next is corrected, so the last
        # frame's file is finished before this one's is started.
        writing&.value
        writing = write_result(result, destination, stem, path, options) do |written|
          puts "  [#{i + 1}/#{files.size}] #{name} -> #{File.basename(written)}"
        end
        if options[:previews]
          jpeg = File.join(preview_dir, "#{stem}.jpg")
          (result * 255).cast(:uchar).thumbnail_image(1600, size: :down)
                        .jpegsave(jpeg, Q: 92)
        end
        sheet&.add(result, stem)
      end
      writing&.value

      File.write(File.join(destination, "settings.yml"),
                 YAML.dump(options.transform_keys(&:to_s)))
      made = sheet&.write(File.join(destination, "contact.jpg"))
      puts "contact sheet -> #{File.basename(made)}" if made
      puts "done"
      0
    ensure
      # An encoder left running would write its file after the run had gone.
      finish(writing)
      Orientation.overrides = {}
    end

    private

    # Settings the roll's fits never see: where and how frames are written,
    # and the strengths put on the raw fits after they are loaded.
    NOT_IN_FITS = %i[out only threads gentle previews contact_sheet format quality bits encoder engine overrides
                     explain audit convert_only crop profile roll_tone roll_fit flat_field
                     match_strength look look_strength].freeze

    MATCH_FILE = "match-reference.yml"

    # A reference measured from rolls already corrected the way they should
    # look, such as a film the lab scanned well on the same day, in place of
    # the profile's. Each is a roll's folder, or a pattern for some of its
    # frames. Kept beside the output and measured again only when those frames
    # or the measuring code change.
    def matched_reference(patterns, destination)
      rolls = patterns.each_with_object({}) do |pattern, found|
        pattern = File.expand_path(pattern)
        paths = if File.directory?(pattern)
                  find_files(pattern, nil)
                else
                  Dir.glob(pattern).select { |path| EXTENSIONS.include?(File.extname(path).delete(".")) }.sort
                end
        raise ArgumentError, "no frames to match in #{pattern}" if paths.empty?

        (found[File.basename(File.dirname(paths.first))] ||= []).concat(paths)
      end
      named = rolls.map { |roll, paths| "#{roll} (#{paths.size} frames)" }.join(" and ")
      @match_rolls = rolls
      key = AnalysisCache.key(rolls.values.flatten, match: rolls.keys)
      path = File.join(destination, MATCH_FILE)
      if File.exist?(path)
        data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        if data.is_a?(Hash) && data["key"] == key
          puts "matching #{named}, as measured before"
          return Reference.load(path)
        end
      end

      puts "measuring #{named} to match..."
      reference = Reference.measure(rolls, id: "match", name: named)
      FileUtils.mkdir_p(destination)
      comment = "Measured by --match from:\n" + rolls.map { |roll, paths| "  #{roll}, #{paths.size} frames" }.join("\n")
      File.write(path, "#{reference.to_yaml(comment)}\nkey: #{key}\n")
      # Read back rather than used as measured, so this run and the next see
      # the same rounded values and the roll's analysis is reused.
      Reference.load(path)
    end

    # The roll is fitted once, across every frame, before any frame is written:
    # first the colour balance toward the reference, then the tone curve and
    # the gamut fit, which both see the roll as balanced. Returns the fits
    # wanted, as the keywords Pipeline takes.
    def analyse_roll(source, destination, profile, reference, options)
      want = {
        balance: reference && options[:roll_balance].positive?,
        tone: reference&.tone_shape && options[:roll_tone].positive?,
        # The gamut fit reopens a film toward what healthy looks like, which the
        # reference measured; a profile may still say so itself.
        fit: options[:roll_fit].positive? && !healthy_spread(profile, reference).nil?,
        flat: options[:fix].include?(:flat) && options[:flat_field].positive?,
        tilt: reference && options[:frame_balance].positive? && options[:lamp_guard].positive?
      }
      return film_look({}, options) unless want.values.any?

      # The tuning, the tilt and the look all read frames at the same size.
      @thumbs = {}
      all = find_files(source, nil)
      # The tuning pass renders frames through the whole pipeline, so every
      # setting it reads changes the balance it settles on, and the key holds
      # them all.
      settings = options.except(*NOT_IN_FITS).merge(fix: options[:fix].sort).sort
      key = AnalysisCache.key(all, healthy_spread: healthy_spread(profile, reference),
                                   neutral: want[:balance] && reference.neutral,
                                   tone_shape: want[:tone] && reference.tone_shape,
                                   settings: settings, orientations: Orientation.overrides.slice(*all))
      cached = AnalysisCache.load(destination, key) || {}
      fits = {}
      fits[:balance] = ColourBalance.from_cache(cached[:balance]) if want[:balance] && cached[:balance]
      fits[:tone] = ToneCurve.from_cache(cached[:tone]) if want[:tone] && cached[:tone]
      fits[:fit] = GamutFit.from_cache(cached[:fit]) if want[:fit] && cached[:fit]
      fits[:flat] = FlatField.from_cache(cached[:flat]) if want[:flat] && cached[:flat]
      fits[:tilt] = cached[:tilt] if want[:tilt] && cached[:tilt]

      # The tilt is measured last, on the finished balance, so it alone
      # missing is no reason to sample the roll again.
      if want.except(:tilt).any? { |name, wanted| wanted && !fits[name] }
        if want[:flat] && !fits[:flat]
          puts "measuring the falloff in the corners..."
          fits[:flat] = FlatField.fit(all) { |_path, image| FrameEdges.detect(image).picture }
        end
        puts "sampling roll of #{all.size} frames..."
        # Sampled inside the picture whether or not the borders are kept, since
        # overscan and rebate are not part of any scene.
        skip = options[:sky_neutral] ? ->(image) { Sky.mask(image) } : nil
        sample = RollSample.collect(all, skip: skip) { |image| FrameEdges.detect(image).picture }
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
          fits[:fit] = GamutFit.new(sample, healthy_spread: healthy_spread(profile, reference))
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
      if want[:tilt] && !fits[:tilt]
        puts "measuring how the roll's frames tilt..."
        fits[:tilt] = roll_tilt(all, options, fits, reference)
        AnalysisCache.save(destination, key, **fits) if fits[:tilt]
      end
      puts format("frames tilt %+.2f stops per e-fold from shadows to highlights", fits[:tilt]) if fits[:tilt]
      if @match_rolls && !options[:monochrome]
        fits[:look] = LookMatch.from_cache(cached[:look]) if cached[:look]
        unless fits[:look]
          puts "measuring the look to match..."
          fits[:look] = match_look(all, options, fits, reference)
          AnalysisCache.save(destination, key, **fits)
        end
        fits[:look].strength = options[:match_strength]
        puts fits[:look].report
      end
      film_look(fits, options).compact
    ensure
      @thumbs = nil
    end

    # The film's own look from its profile, for a roll --match gave none.
    def film_look(fits, options)
      return fits if fits[:look] || !options[:look] || options[:monochrome] || !options[:look_strength].to_f.positive?

      fits[:look] = LookMatch.from_cache(options[:look])
      fits[:look].strength = options[:look_strength]
      puts fits[:look].report(as: "the film's own look")
      fits
    end

    # Frames read from each roll for the look, spread through it.
    LOOK_FRAMES = 12

    # The corrected roll's finished look against the look of the rolls it
    # matches, each read inside the picture, with the colour read below the
    # sky so buildings are compared with buildings. Every matched roll counts
    # the same, however many frames it has.
    def match_look(paths, options, fits, reference)
      film = spread(paths).flat_map do |path|
        rendered = Pipeline.new(options.merge(crop: true), reference: reference, **fits.except(:look))
                           .render(small(path))
        rendered = rendered.copy_memory
        LookMatch.pixels(rendered, sky: Sky.mask(rendered))
      end
      target = @match_rolls.values.flat_map do |frames|
        picked = spread(frames)
        picked.flat_map do |path|
          image = small(path)
          area = FrameEdges.detect(image).picture
          image = image.extract_area(*area).copy_memory if area
          LookMatch.pixels(image, LookMatch::PER_FRAME * LOOK_FRAMES / picked.size, sky: Sky.mask(image))
        end
      end
      LookMatch.fit(film, target)
    end

    def spread(paths)
      step = [paths.size / LOOK_FRAMES, 1].max
      paths.each_slice(step).map(&:first).first(LOOK_FRAMES)
    end

    # The median of how the roll's frames tilt, as the frame balance sees them.
    # A frame is only read as lamp lit by tilting well past this, since some
    # films and some lab sessions tilt every frame.
    def roll_tilt(paths, options, fits, reference)
      tilts = paths.filter_map do |path|
        Pipeline.new(options, reference: reference, **fits.slice(:balance, :flat)).tilt(small(path))
      end
      tilts.empty? ? nil : ColourBalance.percentile(tilts, 50)
    end

    # A frame at the size the roll's measurements read it, in memory, since a
    # thumbnail is read once through and the pipeline goes over a frame several
    # times. Kept while the roll is analysed, so each frame is decoded once.
    def small(path)
      kept = @thumbs && @thumbs[path]
      return kept if kept

      image = Orientation.thumbnail(path, TUNE_WIDTH).copy_memory
      image = image[0..2] if image.bands > 3
      image = image.cast(:float) / (image.format == :ushort ? 65535.0 : 255.0)
      @thumbs[path] = image if @thumbs
      image
    end

    # Off by default, and kept for a roll that wants it named on the command
    # line. The reading does not separate: the seven Superia rolls, which have
    # no drift to find, read 0.18 to 0.30 stops, and the Phoenix rolls read
    # 0.23 to 0.65. Letting it hold the frame balance back left a whole
    # LomoChrome roll with red shadows, at a* +15 to +23 where the frame
    # balance brings them to +0.3 to +8. --explain still reports the drift.
    def measure_frame_balance(source, reference, options)
      return options unless reference && options[:frame_balance].positive? && options[:measured_frame_balance]

      paths = find_files(source, nil)
      step = [paths.size / Diagnosis::FRAMES, 1].max
      frames = Diagnosis.frames_of(paths.each_slice(step).map(&:first).first(Diagnosis::FRAMES))
      drift, = Diagnosis.lab_drift(frames, reference)
      return options unless drift

      share = Diagnosis.ramp(drift, *Diagnosis::LINES[:lab_drift].first(2))
      puts format("  frame to frame drift %.2f stops, so frame balance at %.0f%%", drift, share * 100)
      options.merge(frame_balance: options[:frame_balance] * share)
    end

    # By default libvips takes a thread per core and a roll takes the machine.
    # --threads caps that, and --gentle takes half the cores and drops to a
    # low priority, so a roll can run under other work.
    GENTLE_NICENESS = 10

    def share_the_machine(flags)
      threads = flags[:threads]
      if flags[:gentle]
        threads ||= [Etc.nprocessors / 2, 1].max
        # Only ever lower the priority. A process already running nicer than
        # this may not raise itself back without root, and would fail trying.
        now = Process.getpriority(Process::PRIO_PROCESS, 0)
        Process.setpriority(Process::PRIO_PROCESS, 0, GENTLE_NICENESS) if now < GENTLE_NICENESS
      end
      Vips.concurrency_set(threads) if threads&.positive?
    end

    # Which frames look the wrong way up, as overrides to check and paste in.
    # Nothing is turned. With --contact-sheet, the frames it found are also
    # drawn as written and as suggested.
    def orient(source, files, destination, options)
      all = find_files(source, nil)
      Orientation.overrides = orientations(all, load_overrides(options[:overrides]))
      puts "checking which way up #{files.size} frames are..."
      check = orientation_check
      findings = check.check(files, roll: all)
      puts check.report(findings, files.size)
      return 0 unless options[:contact_sheet] && findings.any?

      FileUtils.mkdir_p(destination)
      made = orientation_sheet(findings, File.basename(source)).write(File.join(destination, "orientation.jpg"))
      puts "as written and as suggested -> #{made}"
      0
    end

    def orientation_check
      OrientationCheck.new
    end

    def orientation_sheet(findings, title)
      sheet = ContactSheet.new("#{title}: which way up")
      findings.each do |found|
        image = Orientation.thumbnail(found.path, ContactSheet::TILE).copy_memory
        image = image[0..2] if image.bands > 3
        image = image.cast(:float) / (image.format == :ushort ? 65535.0 : 255.0)
        sheet.add(image, "#{found.stem} as written")
        turn = (OrientationCheck::TAG_TURN[found.suggested] - OrientationCheck::TAG_TURN[found.written]) % 360
        sheet.add(turn.zero? ? image : image.rot("d#{turn}"), "#{found.stem} as #{found.suggested}")
      end
      sheet
    end

    # The diagnosis on its own, with no frame written.
    def explain(source, reference, options)
      all = find_files(source, nil)
      flat = FlatField.fit(all, verbose: false) { |_path, image| FrameEdges.detect(image).picture }
      diagnosis = Diagnosis.of(all, reference: reference, flat: flat)
      puts diagnosis.report
      puts diagnosis.audit(options) if options[:audit]
      0
    end

    def healthy_spread(profile, reference)
      profile.healthy_spread || reference&.healthy_spread
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
      frames = paths.each_slice(step).map(&:first).first(TUNE_FRAMES).map { |path| small(path) }
      TUNE_ROUNDS.times do
        # Without the lamp guard, which measures frames against the balance
        # this settles on, and cropped, since only the picture is measured.
        rendered = frames.map do |image|
          Pipeline.new(options.merge(crop: true), reference: reference, **fits.except(:tilt)).render(image)
        end
        # The sky is kept out here too. The tuning reads the greys of finished
        # frames, and a sky would vote in this estimate exactly as it does in
        # the frame's own.
        pixels = rendered.flat_map do |image|
          ColourBalance.frame_pixels(image, skip: options[:sky_neutral] ? Sky.mask(image) : nil)
        end
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

    def depth_for(format, bits, encoder = "x265")
      offered = DEPTHS.fetch(format, [8])
      return natural_depth(format, encoder) unless bits

      offered.select { |d| d <= bits }.max || offered.min
    end

    # libheif's own encoder writes ten bits well, as does Apple's; libvips'
    # measured worse than its eight, so eight is what HEIC gets without them.
    def natural_depth(format, encoder = "x265")
      format == "heic" && (HEIF_ENC || encoder == "apple") ? 10 : NATURAL_DEPTH.fetch(format, 8)
    end

    # Written under a temporary name and renamed when complete, so an
    # interrupted run never leaves a truncated file that looks finished.
    # Returns the thread that finishes the file, since heif-enc may still be
    # encoding it, and that thread yields the path when the file is done.
    def write_result(result, destination, stem, source_path, options, &done)
      format = output_format(source_path, options)
      path = File.join(destination, stem + FORMATS.fetch(format))
      partial = "#{path}.partial"
      encoding = save(result, partial, format, options, Orientation.of(source_path), wait: false)
      Thread.new do
        Thread.current.report_on_exception = false
        encoding&.value
        File.rename(partial, path)
        done&.call(path)
        path
      ensure
        File.delete(partial) if File.exist?(partial)
      end
    rescue StandardError
      File.delete(partial) if partial && File.exist?(partial)
      raise
    end

    # Waits for a file still being written, when the run is ending anyway.
    def finish(writing)
      writing&.join
    rescue StandardError
      nil
    end

    # Returns the thread running the HEIC encoder when `wait` is false and there is one.
    def save(result, partial, format, options, orientation, wait: true)
      encoder = options[:encoder] || "x265"
      bits = depth_for(format, options[:bits], encoder)
      quality = options[:quality]
      # A black and white frame is kept as one channel.
      result = result[0] if options[:monochrome]
      # A straight conversion is already whole numbers, and dither would only add noise.
      dither = !options[:convert_only]
      if format == "heic" && (HEIF_ENC || encoder == "apple")
        encoding = encode_heic(result, partial, bits, quality, orientation, dither, encoder: encoder)
        return wait ? encoding.value : encoding
      end

      case format
      # Chroma subsampling smears grain into coloured blocks, so it stays off
      # wherever a format would otherwise apply it.
      when "jpeg"
        quantise(result, 8, dither: dither).jpegsave(partial, Q: quality, subsample_mode: :off,
                                              optimize_coding: true)
      when "heic"
        quantise(result, bits, dither: dither).heifsave(partial, Q: quality, bitdepth: bits, lossless: quality >= 100,
                                                 compression: :hevc, subsample_mode: :off)
      when "jp2"
        tagged(quantise(result, bits, dither: dither), bits).jp2ksave(partial, Q: quality, lossless: quality >= 100,
                                                                      subsample_mode: :off)
      when "png"
        tagged(quantise(result, bits, dither: dither), bits).pngsave(partial, compression: 6)
      else
        quantise(result, bits, dither: dither).tiffsave(partial, compression: :deflate, predictor: :horizontal)
      end
      nil
    end

    # libheif's own encoder, where it is installed. libvips gives the same file
    # for every quality from 95 up and cannot write monochrome; this takes the
    # HEVC quantiser directly, keeps full colour resolution (4:4:4) and writes
    # black and white as true monochrome.
    # The shortest frame written in slices.
    SLICED_HEIGHT = 1024

    HEIF_ENC = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "heif-enc") }
                  .find { |path| File.executable?(path) }

    # The PNG is written here and the encoder runs in the thread returned,
    # which leaves the next frame free to start while this one encodes.
    def encode_heic(result, partial, bits, quality, orientation, dither = true, encoder: "x265")
      png = "#{partial}.png"
      heic = "#{partial}.heic"
      apple = encoder == "apple" && !heif_enc_instead?(result.bands, bits, quality)
      # The PNG it passes through carries no orientation, so the frame is turned
      # upright here.
      frame = quantise(Orientation.upright(result, orientation), bits > 8 ? 16 : 8, dither: dither)
      # Stored rather than compressed: a grainy frame shrinks by 5% at the
      # lightest setting, which cost 3s to write and a second more for heif-enc
      # to read back.
      tagged(frame, bits).pngsave(png, compression: 0)
      qp = ((100 - quality) * 0.51).round.clamp(0, 51)
      args = [HEIF_ENC, "-o", heic]
      args += ["-b", bits.to_s] if bits > 8
      args += ["-p", "chroma=444"] if result.bands > 1
      # The encoder starts a thread per core of its own, so it follows --threads.
      args += ["-p", "x265:pools=#{Vips.concurrency}"]
      # In slices, since libde265, the decoder behind libheif and so most
      # software outside Apple's, cannot open a picture over about 16 MB in one.
      # Only a frame this tall can get near that, and four slices of a short one
      # decode wrong.
      args += ["-p", "x265:slices=4"] if frame.height >= SLICED_HEIGHT
      args += quality >= 100 ? ["-L"] : ["-p", "x265:qp=#{qp}"]
      Thread.new do
        Thread.current.report_on_exception = false
        unless apple && apple_wrote?(png, heic, qp, bits)
          ok = system(*args, png, out: File::NULL, err: File::NULL)
          raise "heif-enc could not write #{File.basename(heic)}" unless ok && File.exist?(heic)
        end

        File.rename(heic, partial)
      ensure
        File.delete(png) if File.exist?(png)
        File.delete(heic) if File.exist?(heic)
      end
    rescue StandardError
      File.delete(png) if png && File.exist?(png)
      raise
    end

    # Apple's hardware encoder, at the same QP as x265. It refuses a frame
    # denser than it has coded cleanly, which heif-enc then writes, and says
    # why when it fails, which goes into the error.
    def apple_wrote?(png, heic, qp, bits)
      said, status = Open3.capture2e(*AppleHeic.command(png, heic, qp: qp, bits: bits, threads: Vips.concurrency))
      said = said.strip.delete_prefix("apple-heic: ")
      if status.exitstatus == AppleHeic::REFUSED
        raise "#{said}, and heif-enc is not installed to write it instead" unless HEIF_ENC

        puts "  #{File.basename(heic, '.partial.heic')}: heif-enc writes it, #{said}"
        return false
      end
      raise "Apple's encoder could not write #{File.basename(heic)}: #{said}" unless status.success? && File.exist?(heic)

      true
    end

    # Whether heif-enc writes a frame Apple's encoder was asked for, which is
    # said once a run.
    def heif_enc_instead?(bands, bits, quality)
      reason = AppleHeic.handed_back(bands, bits, quality)
      return false unless reason
      raise "heif-enc is needed for #{reason}, and it is not installed" unless HEIF_ENC

      @handed_back ||= {}
      puts "  heif-enc writes #{reason}" unless @handed_back[reason]
      @handed_back[reason] = true
    end

    # A quantised frame tagged for its depth and its channels, since the savers
    # read both off the tag: left as sRGB, a one channel frame came out of PNG
    # at eight bits and out of JPEG 2000 as three channels.
    def tagged(frame, bits)
      tag = { [1, true] => :grey16, [1, false] => :b_w, [3, true] => :rgb16, [3, false] => :srgb }
      frame.copy(interpretation: tag.fetch([frame.bands, bits > 8]))
    end

    # A frame as it was scanned, cropped to the picture when --crop asks.
    def converted(path, options)
      scan = Colour.load(path)
      area = options[:crop] && FrameEdges.detect(scan).picture
      area ? scan.extract_area(*area) : scan
    end

    # A float frame in 0..1 as whole numbers at the depth asked for.
    def quantise(result, bits, dither: true)
      top = (1 << bits) - 1
      scaled = result * top
      # Deeper than 8 bits has steps too fine to see, so only 8 needs the noise.
      scaled += Vips::Image.gaussnoise(result.width, result.height, mean: 0.0, sigma: DITHER) if bits == 8 && dither
      scaled = (scaled < 0).ifthenelse(0, (scaled > top).ifthenelse(top, scaled))
      # Rounded, since a cast truncates and a level of 127.9999 is 128.
      scaled.rint.cast(bits > 8 ? :ushort : :uchar)
    end

    # Per-frame overrides, keyed by filename without extension. Values use the
    # long option names, so "saturation: 1.6" under "000057", and
    # "orientation: 8" stands a frame upright when the lab's tag did not.
    def load_overrides(path)
      return {} unless path
      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      raise "overrides file must be a mapping of frame name to settings" unless raw.is_a?(Hash)
      raw.each_with_object({}) do |(frame, settings), acc|
        settings = settings.transform_keys { |k| k.to_s.tr("-", "_").to_sym }
        if settings.key?(:orientation) && !Orientation::VALUES.include?(settings[:orientation])
          raise "orientation for #{frame} must be one of #{Orientation::VALUES.join(', ')}, numbered as EXIF does"
        end

        acc[frame.to_s] = settings
      end
    end

    # The frames whose overrides say which way up they go, by scan path.
    def orientations(paths, overrides)
      paths.each_with_object({}) do |path, table|
        turn = overrides.dig(File.basename(path, ".*"), :orientation)
        table[path] = turn if turn
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

          Usage: filmscan --profile NAME [options] SOURCE_DIR

          Writes corrected frames to "SOURCE_DIR - corrected", in the same format
          they came in as. Originals are never modified. The profile sets the
          colour, tone and grain settings below; any you pass override it.
        BANNER

        opts.separator ""
        opts.on("-p", "--profile NAME",
                "Film stock: #{Profile.available.join(', ')},",
                "or the path to a profile YAML file of your own.") { |v| options[:profile] = v }
        opts.on("--convert-only",
                "No correction, only a new file format, for film the lab",
                "scanned well. Needs no profile.") { |v| options[:convert_only] = v }

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
        opts.on("--match DIR",
                "Balance toward a roll that already looks right, such as one",
                "shot the same day on a film the lab scanned well, in place of",
                "the profile's reference, and carry over its lightness, colour",
                "and colourfulness. Give it once for each roll, or a pattern",
                "for some of its frames.") { |v| (options[:match] ||= []) << v }
        opts.on("--match-strength FLOAT", Float,
                "How much of the matched rolls' look to carry over, 0 to 1",
                "(default #{DEFAULTS[:match_strength]}).") { |v| options[:match_strength] = v }
        opts.on("--look-strength FLOAT", Float,
                "How much of the film's own look, from its profile, to carry",
                "over when there is no --match, 0 to 1 (the profile's own, or",
                "#{DEFAULTS[:look_strength]}).") { |v| options[:look_strength] = v }
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
        opts.on("--lamp-guard FLOAT", Float,
                "How much of a lamp lit frame's warmth the frame balance leaves,",
                "0 to 1, by how sure it is of the lamps (default #{DEFAULTS[:lamp_guard]}).") { |v| options[:lamp_guard] = v }
        opts.on("--keep-warmth FLOAT", Float,
                "Share of the frame balance's warm to cool move to leave out,",
                "0 to 1, for golden hour. Best as a per-frame override.") { |v| options[:keep_warmth] = v }
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
        opts.on("--crop",
                "Take off the film borders and the scanner's overscan. They",
                "stay by default, and are never measured either way.") { |v| options[:crop] = v }
        opts.on("--flat-field FLOAT", Float,
                "Strength of the lift in the corners, 0 to 1",
                "(default #{DEFAULTS[:flat_field]}).") { |v| options[:flat_field] = v }
        opts.on("--recovery FLOAT", Float,
                "Strength of the shadow and highlight recovery, 0 to 1",
                "(default #{DEFAULTS[:recovery]}).") { |v| options[:recovery] = v }
        opts.on("--sky-headroom STOPS", Float,
                "Highlight headroom for frames with a sky in them, when that",
                "is more than the rest get (default #{DEFAULTS[:sky_headroom]}).") { |v| options[:sky_headroom] = v }
        opts.on("--sky-floor STOPS", Float,
                "How far a sky that came out warm may be brought back toward",
                "neutral (default #{DEFAULTS[:sky_floor]}). Never pushed past it, and",
                "never applied to a sky that is already blue.") { |v| options[:sky_floor] = v }
        opts.on("--[no-]sky-neutral",
                "Keep a detected sky out of the frame's neutral estimate",
                "(default #{DEFAULTS[:sky_neutral]}). A pale sky is large, smooth and",
                "near neutral, so the fit adopts it as the grey card.") { |v| options[:sky_neutral] = v }
        opts.on("--highlight-headroom STOPS", Float,
                "How far a pixel may be darkened when a gain would take it",
                "past white (default #{DEFAULTS[:highlight_headroom]}). Zero clips it instead,",
                "which flattens skies on films whose blue has to come up.") { |v| options[:highlight_headroom] = v }
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
        opts.on("--encoder NAME", %w[x265 apple],
                "HEIC encoder: x265 (default), or apple, Apple's hardware",
                "encoder on macOS. apple is five to seven times faster and",
                "leaves the cores free, for files about 15% larger. Black and",
                "white, and frames denser than it was tested on, go to x265.",
                *(AppleHeic.available? ? [] : ["apple needs macOS and `rake apple_heic` first."])) { |v| options[:encoder] = v }
        opts.on("--engine NAME", %w[vips apple],
                "What works out each frame: apple, which runs the per-pixel",
                "colour work and the blurs as Metal kernels, or vips. apple is",
                "the default on a Mac where `rake apple_engine` has built it.",
                "Frames come out the same to within float rounding.",
                *(Metal.available? ? [] : ["apple needs macOS and `rake apple_engine` first."])) { |v| options[:engine] = v }
        opts.on("--previews", "--jpeg", "Also write 1600px preview JPEGs.") { |v| options[:previews] = v }
        opts.on("--[no-]measured-frame-balance",
                "Hold the frame balance back on a roll whose frames measure",
                "steady (default #{DEFAULTS[:measured_frame_balance]}). The reading does not",
                "separate well, so this is off.") { |v| options[:measured_frame_balance] = v }
        opts.on("--threads N", Integer,
                "Threads for the image work (default: one per core).") { |v| options[:threads] = v }
        opts.on("--gentle",
                "Use half the cores at low priority, so the machine stays",
                "usable for other work while a roll corrects.") { |v| options[:gentle] = v }
        opts.on("--contact-sheet",
                "Also write contact.jpg, every frame of the roll on one sheet",
                "with its number under it.") { |v| options[:contact_sheet] = v }
        opts.on("--explain", "Say what the roll shows is wrong with it, and stop.") { |v| options[:explain] = v }
        opts.on("--audit", "Say what the roll shows and what the profile does",
                "about each thing, and stop.") { |v| options[:audit] = v }
        opts.on("--orient", "Say which frames look the wrong way up, as overrides",
                "to check and paste in, and stop. Needs no profile, and needs",
                "the onnxruntime gem: see the README.") { |v| options[:orient] = v }
        opts.on("--only GLOB", "Filter frames, for example '0000[45]*'.") { |v| options[:only] = v }
        opts.on("--overrides FILE", "YAML of per-frame settings, keyed by filename",
                "without extension. An orientation (1, 3, 6 or 8, as EXIF",
                "numbers them) stands up a frame the lab tagged wrongly.") { |v| options[:overrides] = v }

        opts.separator ""
        opts.on("-h", "--help", "Show this message.") do
          puts opts
          exit 0
        end
        opts.on("-v", "--version", "Show version.") do
          puts FilmScan::VERSION
          exit 0
        end
      end
    end
  end
end
