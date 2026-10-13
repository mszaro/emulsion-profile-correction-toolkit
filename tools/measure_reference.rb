#!/usr/bin/env ruby
# Measures how well-scanned rolls of a film render neutral at each tone and
# where their tones fall, and writes it to references/ for profiles to balance
# other films toward.
#
#   measure_reference.rb ID "Film name" ROLL_DIR [ROLL_DIR ...]

require_relative "../lib/film_scan"
require_relative "../lib/film_scan/cli"

id, name, *dirs = ARGV
if dirs.empty?
  warn 'usage: measure_reference.rb ID "Film name" ROLL_DIR [ROLL_DIR ...]'
  exit 1
end

exts = FilmScan::CLI::EXTENSIONS.join(",")
rolls = dirs.to_h do |dir|
  [File.basename(dir), Dir.glob(File.join(File.expand_path(dir), "*.{#{exts}}")).uniq.sort]
end

begin
  reference = FilmScan::Reference.measure(rolls, id: id, name: name)
rescue ArgumentError => e
  abort e.message
end

path = File.join(FilmScan::Reference::DIR, "#{id}.yml")
comment = "#{name}, measured by tools/measure_reference.rb from #{dirs.size} rolls:\n" +
          rolls.keys.map { |roll| "  #{roll}" }.join("\n")
File.write(path, reference.to_yaml(comment))
puts "wrote #{path}"
