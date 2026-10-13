#!/usr/bin/env ruby
# Measures the shape of a film's colour against the reference its profile
# names, and writes it into the profile as chroma_map. Both sides are read
# after the per-channel correction, so what is fitted is only what the gains
# could not reach.
#
#   measure_shape.rb PROFILE --reference REF_DIR[,REF_DIR...] ROLL_DIR [ROLL_DIR ...]

require "json"
require_relative "../lib/film_scan"
require_relative "../lib/film_scan/cli"

name = ARGV.shift
reference_dirs = []
ARGV.delete_if.with_index do |arg, i|
  next false unless arg == "--reference"

  reference_dirs = ARGV[i + 1].to_s.split(",")
  true
end
ARGV.delete(reference_dirs.join(",")) unless reference_dirs.empty?
dirs = ARGV
if name.nil? || dirs.empty? || reference_dirs.empty?
  warn "usage: measure_shape.rb PROFILE --reference REF_DIR[,REF_DIR] ROLL_DIR [ROLL_DIR ...]"
  exit 1
end

profile = FilmScan::Profile.load(name)
reference = FilmScan::Reference.load(profile.settings[:reference] || abort("profile names no reference"))
exts = FilmScan::CLI::EXTENSIONS.join(",")

# The film, corrected the way the pipeline corrects it before anything here.
def pixels_of(dirs, exts, film_gains, target)
  dirs.flat_map do |dir|
    paths = Dir.glob(File.join(File.expand_path(dir), "*.{#{exts}}")).uniq.sort
    abort "no images in #{dir}" if paths.empty?

    puts File.basename(dir)
    sample = FilmScan::RollSample.collect(paths) { |image| FilmScan::FrameEdges.detect(image).picture }
    offsets = FilmScan::ColourBalance.black_offsets(sample)
    pixels = FilmScan::ColourBalance.linear_pixels(sample, offsets)
    next pixels unless film_gains

    balance = FilmScan::ColourBalance.fit_roll(sample, target, film: film_gains)
    FilmScan::ColourBalance.linear_pixels(balance.apply_to_sample(sample), [0, 0, 0])
  end
end

# Each frame as the map receives it: the roll's balance, when the film has
# one, then the frame's own. Both films are read this way, since a frame
# balance narrows how far colour spreads across a roll, and a spread from
# one side without it would read as the film's own.
def balanced_pixels(dirs, exts, settings, reference)
  options = FilmScan::DEFAULTS.merge(settings).merge(fix: %i[crop floor], chroma_shape: 0.0, lost_colour: 0.0)
  dirs.flat_map do |dir|
    paths = Dir.glob(File.join(File.expand_path(dir), "*.{#{exts}}")).uniq.sort
    abort "no images in #{dir}" if paths.empty?

    puts File.basename(dir)
    balance = nil
    if settings[:film_gains]
      sample = FilmScan::RollSample.collect(paths) { |image| FilmScan::FrameEdges.detect(image).picture }
      balance = FilmScan::ColourBalance.fit_roll(sample, reference.neutral, film: settings[:film_gains])
      balance.strength = options[:roll_balance]
    end
    pixels = paths.each_with_index.flat_map do |path, i|
      print "\r  balancing #{i + 1}/#{paths.size}"
      frame = FilmScan::Pipeline.new(options, balance: balance, reference: reference)
                                .balanced(FilmScan::Colour.load(path))
      # Every sixteenth of the frame balance's own sample: single pixels,
      # since averaging neighbours would narrow the spread.
      frame ? FilmScan::ColourBalance.frame_pixels(frame).each_slice(16).map(&:first) : []
    end
    puts
    pixels
  end
end

if profile.settings[:frame_balance].to_f.positive?
  film = balanced_pixels(dirs, exts, profile.settings, reference)
  shot = balanced_pixels(reference_dirs, exts, { frame_balance: 1.0 }, reference)
else
  film = pixels_of(dirs, exts, profile.settings[:film_gains], reference.neutral)
  shot = pixels_of(reference_dirs, exts, nil, reference.neutral)
end
map = FilmScan::ChromaMap.fit(film, shot, FilmScan::ChromaMap.grey_of(reference.neutral)) or
  abort "too few pixels to measure a shape"
puts map.report

block = <<~YAML
  # How this film's colour sits against #{reference.name}, after the gains
  # above have done what they can, measured by tools/measure_shape.rb from:
  #{dirs.map { |d| "#   #{File.basename(d)}" }.join("\n")}
  # against:
  #{reference_dirs.map { |d| "#   #{File.basename(d)}" }.join("\n")}
  chroma_map:
    matrix: [#{map.matrix.map { |v| format('%.4f', v) }.join(', ')}]
    offset: [#{map.offset.map { |v| format('%.4f', v) }.join(', ')}]
YAML

path = File.join(FilmScan::Profile::DIR, "#{profile.id}.yml")
text = File.read(path)
# One line per entry: under /m a dot also matches a newline, so .* would
# run on to the end of the profile and take every setting after it.
existing = /^# How this film's colour sits against.*?\nchroma_map:\n(?:  \w+: [^\n]*\n)+/m
text = if text.match?(existing)
         text.sub(existing, block)
       else
         text.sub(/^(film_gains:\n(?:  - .*\n)+)/) { "#{Regexp.last_match(1)}\n#{block}" }
       end
abort "could not find where to put chroma_map in #{path}" unless text.include?("chroma_map:")
# Checked before it is written, so a bad edit never leaves a broken profile.
FilmScan::Profile.new(profile.id, YAML.safe_load(text, permitted_classes: [], aliases: false, symbolize_names: true))
File.write(path, text)
FilmScan::Profile.load(profile.id)
puts "wrote chroma_map to #{path}"
