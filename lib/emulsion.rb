require "vips"

# vips caches operations, which helps on one image and leaks across a long
# batch. Every frame here is a fresh pipeline, so keep nothing between them.
Vips.cache_set_max(0)
Vips.cache_set_max_mem(256 * 1024 * 1024)

require_relative "emulsion/version"
require_relative "emulsion/colour"
require_relative "emulsion/measurements"
require_relative "emulsion/profile"
require_relative "emulsion/analysis_cache"
require_relative "emulsion/roll_sample"
require_relative "emulsion/colour_balance"
require_relative "emulsion/tone_curve"
require_relative "emulsion/reference"
require_relative "emulsion/gamut_fit"
require_relative "emulsion/pipeline"

# Corrects lab scans of film stocks the scanner had no profile for. What is
# known about each film lives in its profile; the code is the same for all.
module Emulsion
  # Settings that are not about any one film. The rest come from the profile.
  DEFAULTS = {
    format: nil,
    quality: 98,
    roll_fit: 1.0,
    reference: nil,
    roll_balance: 1.0,
    roll_balance_limit: 1.0,
    film_gains: nil,
    frame_balance: 0.0,
    frame_balance_limit: 2.5,
    roll_tone: 0.0,
    saturation: nil,
    chroma_radius: nil
  }.freeze
end
