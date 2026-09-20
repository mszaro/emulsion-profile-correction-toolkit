#!/usr/bin/env ruby
# Measures the shape of a film's colour against the reference its profile
# names, and writes it into the profile as chroma_map. Both sides are read
# after the per-channel correction, so what is fitted is only what the gains
# could not reach.
#
#   measure_shape.rb PROFILE --reference REF_DIR[,REF_DIR...] ROLL_DIR [ROLL_DIR ...]

require "json"
require_relative "../lib/emulsion"
require_relative "../lib/emulsion/cli"

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

profile = Emulsion::Profile.load(name)
reference = Emulsion::Reference.load(profile.settings[:reference] || abort("profile names no reference"))
exts = Emulsion::CLI::EXTENSIONS.join(",")

# The film, corrected the way the pipeline corrects it before anything here.
def pixels_of(dirs, exts, film_gains, target)
  dirs.flat_map do |dir|
    paths = Dir.glob(File.join(File.expand_path(dir), "*.{#{exts}}")).uniq.sort
    abort "no images in #{dir}" if paths.empty?

    puts File.basename(dir)
    sample = Emulsion::RollSample.collect(paths) { |image| Emulsion::FrameEdges.detect(image).picture }
    offsets = Emulsion::ColourBalance.black_offsets(sample)
    pixels = Emulsion::ColourBalance.linear_pixels(sample, offsets)
    next pixels unless film_gains

    balance = Emulsion::ColourBalance.fit_roll(sample, target, film: film_gains)
    Emulsion::ColourBalance.linear_pixels(balance.apply_to_sample(sample), [0, 0, 0])
  end
end

film = pixels_of(dirs, exts, profile.settings[:film_gains], reference.neutral)
shot = pixels_of(reference_dirs, exts, nil, reference.neutral)
map = Emulsion::ChromaMap.fit(film, shot) or abort "too few pixels to measure a shape"
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

path = File.join(Emulsion::Profile::DIR, "#{profile.id}.yml")
text = File.read(path)
existing = /^# How this film's colour sits against.*?\nchroma_map:\n(?:  \w+: .*\n)+/m
text = if text.match?(existing)
         text.sub(existing, block)
       else
         text.sub(/^(film_gains:\n(?:  - .*\n)+)/) { "#{Regexp.last_match(1)}\n#{block}" }
       end
abort "could not find where to put chroma_map in #{path}" unless text.include?("chroma_map:")
File.write(path, text)
Emulsion::Profile.load(profile.id)
puts "wrote chroma_map to #{path}"
