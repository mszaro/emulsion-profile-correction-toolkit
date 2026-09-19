require_relative "lib/emulsion/version"

Gem::Specification.new do |spec|
  spec.name = "emulsion"
  spec.version = Emulsion::VERSION
  spec.authors = ["mszaro"]
  spec.summary = "Correct lab scans of film stocks the scanner had no profile for"
  spec.description = <<~TEXT
    Labs scan unusual film stocks with a profile meant for another film, and
    the scans come back flat and colour shifted. This corrects them, using a
    profile for each supported stock.
  TEXT
  spec.homepage = "https://github.com/mszaro/emulsion-profile-correction-toolkit"
  spec.license = "PolyForm-Noncommercial-1.0.0"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "bin/*", "profiles/*.yml", "references/*.yml", "README.md",
                   "LICENSE.md"]
  spec.bindir = "bin"
  spec.executables = ["emulsion"]
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby-vips", "~> 2.2"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.0"
end
