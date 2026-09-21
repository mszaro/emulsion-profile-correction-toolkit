#!/usr/bin/env ruby
# Measures how well-scanned rolls of a film render neutral at each tone and
# where their tones fall, and writes it to references/ for profiles to balance
# other films toward.
#
#   measure_reference.rb ID "Film name" ROLL_DIR [ROLL_DIR ...]

require "json"
require_relative "../lib/emulsion"
require_relative "../lib/emulsion/cli"

id, name, *dirs = ARGV
if dirs.empty?
  warn 'usage: measure_reference.rb ID "Film name" ROLL_DIR [ROLL_DIR ...]'
  exit 1
end

# Each roll gets an equal say in the neutral, whatever its length.
PER_ROLL = 60_000

exts = Emulsion::CLI::EXTENSIONS.join(",")
pixels = []
shapes = []
spreads = []
dirs.each do |dir|
  paths = Dir.glob(File.join(File.expand_path(dir), "*.{#{exts}}")).uniq.sort
  abort "no images in #{dir}" if paths.empty?

  puts File.basename(dir)
  # Inside the picture, as measure_shape.rb samples, since the scanner's
  # borders are not part of any scene.
  sample = Emulsion::RollSample.collect(paths) { |image| Emulsion::FrameEdges.detect(image).picture }
  offsets = Emulsion::ColourBalance.black_offsets(sample)
  roll = Emulsion::ColourBalance.linear_pixels(sample, offsets)
  pixels.concat(roll.each_slice([roll.size / PER_ROLL, 1].max).map(&:first))
  shapes << Emulsion::ToneCurve.shape_of(sample)
  # How widely a well scanned roll spreads its colour, so the gamut fit knows
  # what healthy looks like on the film it is aiming at.
  spreads << Emulsion::GamutFit.new(sample, healthy_spread: 0.0, verbose: false).spread_before
end

# A well-scanned film has no large cast to find first, so each band is read
# from the greys nearest neutral rather than from whatever fills it.
zero = Array.new(Emulsion::ColourBalance::TONES.size) { [0.0, 0.0] }
neutral = Emulsion::ColourBalance.neutral_by_tone(pixels, from: zero)
abort "too few pixels to measure a neutral" if neutral.compact.size < 2
neutral = Emulsion::ColourBalance.fill_gaps(neutral)
spread = Emulsion::Measurements.percentile(spreads.sort, 50)
shape = shapes.transpose.map { |values| Emulsion::Measurements.percentile(values.sort, 50) }

path = File.join(Emulsion::Reference::DIR, "#{id}.yml")
File.write(path, <<~YAML)
  # #{name}, measured by tools/measure_reference.rb from #{dirs.size} rolls:
  #{dirs.map { |d| "#   #{File.basename(d)}" }.join("\n")}
  name: #{name.to_json}

  # Neutral is [red, blue] in stops relative to green, at each tone band.
  tones: [#{Emulsion::ColourBalance::TONES.join(', ')}]
  neutral:
  #{neutral.map { |r, b| format('  - [%.3f, %.3f]', r, b) }.join("\n")}

  # Where a typical frame's luma falls, at #{Emulsion::ToneCurve::QUANTILES.join(', ')} percent,
  # once stretched between its #{Emulsion::ToneCurve::BLACK} and #{Emulsion::ToneCurve::WHITE} percentiles.
  tone_shape: [#{shape.map { |v| format('%.3f', v) }.join(', ')}]

  # How widely a typical roll spreads its colour across hues, the median of
  # the rolls above. The gamut fit reopens a film toward this and no further.
  healthy_spread: #{format('%.3f', spread)}
YAML
puts "wrote #{path}"
