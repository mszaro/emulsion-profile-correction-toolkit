require "vips"

# vips caches operations, which helps on one image and leaks across a long
# batch. Every frame here is a fresh pipeline, so keep nothing between them.
Vips.cache_set_max(0)
Vips.cache_set_max_mem(256 * 1024 * 1024)

require_relative "film_scan/version"
require_relative "film_scan/colour"
require_relative "film_scan/orientation"
require_relative "film_scan/orientation_check"
require_relative "film_scan/measurements"
require_relative "film_scan/profile"
require_relative "film_scan/analysis_cache"
require_relative "film_scan/roll_sample"
require_relative "film_scan/frame_edges"
require_relative "film_scan/flat_field"
require_relative "film_scan/colour_balance"
require_relative "film_scan/tone_curve"
require_relative "film_scan/dynamics"
require_relative "film_scan/detail"
require_relative "film_scan/highlights"
require_relative "film_scan/gamut"
require_relative "film_scan/sky"
require_relative "film_scan/warm_light"
require_relative "film_scan/diagnosis"
require_relative "film_scan/contact_sheet"
require_relative "film_scan/apple_heic"
require_relative "film_scan/lost_colour"
require_relative "film_scan/chroma_map"
require_relative "film_scan/reference"
require_relative "film_scan/gamut_fit"
require_relative "film_scan/look_match"
require_relative "film_scan/fused"
require_relative "film_scan/pipeline"

# Corrects lab scans of film stocks the scanner had no profile for. What is
# known about each film lives in its profile; the code is the same for all.
module FilmScan
  # Corrections that are about the camera, the scanner or the frame rather
  # than the film, each only run when --fix asks for it. DEFAULT_FIXES is what
  # a bare --fix turns on.
  FIXES = %i[floor flat shadows sharpen grain].freeze
  DEFAULT_FIXES = %i[floor flat shadows sharpen grain].freeze

  # Settings that are not about any one film. The rest come from the profile.
  DEFAULTS = {
    format: nil,
    quality: 98,
    # heif-enc with x265, or Apple's hardware encoder on macOS.
    encoder: "x265",
    # Metal for the per-pixel work on a Mac where `rake apple_engine` has
    # built it, libvips everywhere else. Chosen when a run starts.
    engine: nil,
    bits: nil,
    roll_fit: 1.0,
    reference: nil,
    roll_balance: 1.0,
    roll_balance_limit: 1.0,
    film_gains: nil,
    frame_balance: 0.0,
    frame_balance_limit: 2.5,
    lamp_guard: 1.0,
    keep_warmth: 0.0,
    frame_tint_limit: nil,
    roll_tone: 0.0,
    fix: [],
    # The film borders stay unless --crop takes them off. Either way the
    # correction is measured on the picture alone.
    crop: false,
    # How much of the matched rolls' look --match carries over, 0 to 1.
match_strength: 1.0,
# A film's own look, learned by tools/measure_look.rb from rolls shot
# alongside rolls a lab scanned well, and how much of it a roll takes.
# --match gives a roll its own in its place.
look: nil,
look_strength: 1.0,
    # Off unless a profile asks: the falloff is measured across a roll, and a
    # roll of skies and dark ground does not average out the way the fit needs.
    flat_field: 0.0,
    recovery: 1.0,
    sharpness: 0.7,
    highlight_headroom: 0.0,
    sky_neutral: false,
    sky_floor: 0.0,
    sky_headroom: 0.0,
    contact_sheet: false,
    measured_frame_balance: false,
    lost_colour: 0.0,
    chroma_map: nil,
    chroma_shape: 0.0,
    saturation: nil,
    chroma_radius: nil
  }.freeze
end
