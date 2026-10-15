#!/usr/bin/env ruby
# Learns a film's own look from rolls of it shot alongside rolls a lab scanned
# well, and writes it into the film's profile as look. Each pair is a roll of
# the film and the rolls shot with it, given as folders or as patterns for
# some of their frames. Every roll counts the same.
#
# Only the lightness is kept unless --colour asks for the average colour too.
# Across seven cities the lightness carried from one city to another for both
# films tried, the colour only for Harman Phoenix, whose lab sessions drifted
# alike, and how colourful a roll came out never did, so that is left alone.
#
#   measure_look.rb PROFILE [--colour] [--strength N] ROLL=SIBLING[,SIBLING ...] ...

require "optparse"
require "tmpdir"
require_relative "../lib/film_scan"
require_relative "../lib/film_scan/cli"

colour = false
strength = 1.0
OptionParser.new do |opts|
  opts.banner = "usage: measure_look.rb PROFILE [--colour] [--strength N] ROLL=SIBLING[,SIBLING ...] ..."
  opts.on("--colour", "Keep the average colour per brightness as well") { colour = true }
  opts.on("--strength N", Float, "look_strength to write (default 1.0)") { |v| strength = v }
end.parse!
name, *pairs = ARGV
abort "usage: measure_look.rb PROFILE [--colour] [--strength N] ROLL=SIBLING[,SIBLING ...] ..." if pairs.empty?

profile = FilmScan::Profile.load(name)
pairs = pairs.map do |pair|
  roll, siblings = pair.split("=", 2)
  abort "#{pair}: give the roll, then = and the rolls shot with it" unless roll && siblings
  [File.expand_path(roll), siblings.split(",").map { |s| File.expand_path(s) }]
end

cli = FilmScan::CLI.new
cli.instance_variable_set(:@thumbs, {})
sample = FilmScan::LookMatch::PER_FRAME * FilmScan::CLI::LOOK_FRAMES
thin = lambda do |pixels|
  step = [pixels.size.to_f / sample, 1.0].max
  (0...[sample, pixels.size].min).map { |i| pixels[(i * step).floor] }
end

# Each roll as a render corrects it, with the fixes a render would get from a
# bare --fix and without the look this is about to replace.
options = FilmScan::DEFAULTS.merge(profile.settings)
                            .merge(fix: FilmScan::DEFAULT_FIXES.dup, profile: name, look: nil)
options[:engine] = FilmScan::Metal.default_engine
reference = options[:reference] && FilmScan::Reference.load(options[:reference])
film = []
target = []
pairs.each do |roll, siblings|
  puts File.basename(roll)
  Dir.mktmpdir do |cache|
    out = $stdout
    $stdout = File.open(File::NULL, "w")
    roll_options = cli.send(:measure_frame_balance, roll, reference, options)
    fits = cli.send(:analyse_roll, roll, cache, profile, reference, roll_options)
    $stdout = out
    frames = cli.send(:spread, cli.send(:find_files, roll, nil))
    film.concat(thin.(frames.flat_map do |path|
      rendered = FilmScan::Pipeline.new(roll_options.merge(crop: true), reference: reference, **fits)
                                   .render(cli.send(:small, path)).copy_memory
      FilmScan::LookMatch.pixels(rendered, sky: FilmScan::Sky.mask(rendered))
    end))
  end
  groups = siblings.each_with_object({}) do |pattern, found|
    paths = File.directory?(pattern) ? cli.send(:find_files, pattern, nil) : Dir.glob(pattern).sort
    paths = paths.select { |p| FilmScan::CLI::EXTENSIONS.include?(File.extname(p).delete(".").downcase) }
    abort "no frames in #{pattern}" if paths.empty?
    (found[File.dirname(paths.first)] ||= []).concat(paths)
  end
  target.concat(thin.(groups.values.flat_map do |frames|
    picked = cli.send(:spread, frames)
    picked.flat_map do |path|
      image = cli.send(:small, path)
      area = FilmScan::FrameEdges.detect(image).picture
      image = image.extract_area(*area).copy_memory if area
      FilmScan::LookMatch.pixels(image, sample / picked.size, sky: FilmScan::Sky.mask(image))
    end
  end))
end

fitted = FilmScan::LookMatch.fit(film, target)
data = fitted.to_h
means = data["film"]
data["offsets"] = if colour
                    data["offsets"].each_with_index.map { |o, b| (0..1).map { |c| o[c] + (data["spread"] - 1.0) * means[b][c] } }
                  else
                    Array.new(data["offsets"].size) { [0.0, 0.0] }
                  end
data["spread"] = 1.0
data.delete("film") unless colour
learned = FilmScan::LookMatch.from_cache(data.transform_keys(&:to_sym))
learned.strength = strength
puts learned.report(as: "learned")

row = ->(pair) { format("[%.2f, %.2f]", *pair) }
kept = colour ? "Lightness and the average colour at each brightness" : "Lightness only"
block = <<~YAML
  # The film's own look against rolls shot alongside it, learned by
  # tools/measure_look.rb from #{pairs.size} pairs. #{kept}; --match gives a
  # roll its own instead.
  #{pairs.map { |roll, siblings| "#   #{File.basename(roll)} with #{siblings.map { |s| File.basename(s.sub(%r{/[^/]*[*?\[][^/]*\z}, '')) }.join(', ')}" }.join("\n")}
  look:
    lightness:
  #{data['lightness'].map { |p| "    - #{row.(p)}" }.join("\n")}
    offsets:
  #{data['offsets'].map { |p| "    - #{row.(p)}" }.join("\n")}
  #{colour ? "  film:\n#{means.map { |p| "    - #{row.(p)}" }.join("\n")}\n" : ''}  spread: 1.0
  look_strength: #{strength}
YAML
block = block.gsub(/\n\n+/, "\n").sub(/\n  spread/, "\n  spread")

path = File.join(FilmScan::Profile::DIR, "#{profile.id}.yml")
text = File.read(path)
existing = /^# The film's own look against rolls.*?\nlook_strength: [^\n]*\n/m
text = text.match?(existing) ? text.sub(existing, block) : "#{text.chomp}\n\n#{block}"
# Checked before it is written, so a bad edit never leaves a broken profile.
FilmScan::Profile.new(profile.id, YAML.safe_load(text, permitted_classes: [], aliases: false, symbolize_names: true))
File.write(path, text)
FilmScan::Profile.load(profile.id)
puts "wrote look to #{path}"
