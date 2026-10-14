module FilmScan
  # sRGB transfer curves, written out rather than using colourspace(:srgb).
  #
  # libvips treats sRGB as 8-bit, which would round these 0..1 floats in the
  # middle of a pipeline that is stretching tones apart. Everything stays float.
  module Colour
    module_function

    def to_linear(image)
      low = image / 12.92
      high = ((image + 0.055) / 1.055)**2.4
      (image <= 0.04045).ifthenelse(low, high)
    end

    def to_srgb(image)
      image = clamp01(image)
      low = image * 12.92
      high = (image**(1 / 2.4)) * 1.055 - 0.055
      clamp01((image <= 0.0031308).ifthenelse(low, high))
    end

    # Scalar version, for building lookup tables in plain Ruby.
    def srgb_to_linear_scalar(v)
      v <= 0.04045 ? v / 12.92 : (((v + 0.055) / 1.055)**2.4)
    end

    def clamp01(image)
      image = (image < 0).ifthenelse(0, image)
      (image > 1).ifthenelse(1, image)
    end

    # Load as float 0..1 sRGB, from an 8-bit or a 16-bit scan. Extra bands are
    # dropped and a greyscale scan is fanned out to three channels. The frame
    # carries its orientation override, if it has one, in place of its tag.
    def load(path)
      image = Vips::Image.new_from_file(path, access: :random)
      image = image.bandjoin([image, image]) if image.bands == 1
      image = image[0..2] if image.bands > 3
      Orientation.apply(image.cast(:float) / (image.format == :ushort ? 65535.0 : 255.0), path)
    end
  end
end
