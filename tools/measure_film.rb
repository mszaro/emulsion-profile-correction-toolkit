#!/usr/bin/env ruby
# Measures a film's own cast from several rolls a lab scanned without its
# profile, against the reference its profile names, and writes it into the
# profile as film_gains. The more varied the rolls, the less any one roll's
# scenes colour the result.
#
#   measure_film.rb PROFILE ROLL_DIR [ROLL_DIR ...]

require_relative "../lib/emulsion"
require_relative "../lib/emulsion/cli"

name, *dirs = ARGV
if dirs.empty?
  warn "usage: measure_film.rb PROFILE ROLL_DIR [ROLL_DIR ...]"
  exit 1
end

profile = Emulsion::Profile.load(name)
reference_name = profile.settings[:reference] or abort "profile #{name} names no reference"
reference = Emulsion::Reference.load(reference_name)

exts = Emulsion::CLI::EXTENSIONS.join(",")
samples = dirs.map do |dir|
  paths = Dir.glob(File.join(File.expand_path(dir), "*.{#{exts}}")).uniq.sort
  abort "no images in #{dir}" if paths.empty?

  puts File.basename(dir)
  # Inside the picture, as measure_shape.rb samples, since the scanner's
  # borders are not part of any scene.
  Emulsion::RollSample.collect(paths) { |image| Emulsion::FrameEdges.detect(image).picture }
end

gains = Emulsion::ColourBalance.fit_film(samples, reference.neutral)
block = <<~YAML
  # The film's own cast, per tone, as [red, green, blue] stops, measured by
  # tools/measure_film.rb against #{reference.name} from #{dirs.size} rolls:
  #{dirs.map { |d| "#   #{File.basename(d)}" }.join("\n")}
  film_gains:
  #{gains.map { |g| format('  - [%.3f, %.3f, %.3f]', *g) }.join("\n")}
YAML

path = File.join(Emulsion::Profile::DIR, "#{profile.id}.yml")
text = File.read(path)
# One line per entry: under /m a dot also matches a newline, so .* would
# run on to the end of the profile and take every setting after it.
existing = /^# The film's own cast, per tone.*?\nfilm_gains:\n(?:  - [^\n]*\n)+/m
text = if text.match?(existing)
         text.sub(existing, block)
       else
         text.sub(/^(roll_balance: .*\n)/) { "#{Regexp.last_match(1)}\n#{block}\n" }
       end
abort "could not find where to put film_gains in #{path}" unless text.include?(block)
# Checked before it is written, so a bad edit never leaves a broken profile.
Emulsion::Profile.new(profile.id, YAML.safe_load(text, permitted_classes: [], aliases: false, symbolize_names: true))
File.write(path, text)
Emulsion::Profile.load(profile.id)
puts "wrote film_gains to #{path}"
