require_relative "metal"

module FilmScan
  # A per-pixel expression over a whole frame, built by the same calls that
  # build a libvips pipeline and worked out as one Metal kernel when anything
  # needs its pixels: a blur, a measurement, a write. --engine apple starts a
  # frame as one, and every stage takes it for a Vips::Image.
  #
  # Each step libvips takes as a pass of its own is a line of the kernel here,
  # so a stage of thirty steps reads the frame once and writes it once.
  # Constants and tables reach the GPU as data, so a stage compiles once a run
  # however its numbers move from frame to frame. Whatever it cannot fuse goes
  # to libvips as it always did, and the answer comes back as a new start.
  class Fused
    Const = Struct.new(:values)

    INTS = %i[uchar char ushort short uint int].freeze
    WIDER = %i[uchar char ushort short uint int float double].freeze
    RANGES = { uchar: [0, 255], char: [-128, 127], ushort: [0, 65_535], short: [-32_768, 32_767],
               uint: [0, 4_294_967_295], int: [-2_147_483_648, 2_147_483_647] }.freeze
    # Metal takes 31 buffers; three are the constants, the output and the size.
    MAX_INPUTS = 28

    BINARY = { add: "(%s + %s)", sub: "(%s - %s)", mul: "(%s * %s)", div: "fs_div(%s, %s)",
               pow: "fs_pow(%s, %s)", lt: "(%s < %s ? 255.0f : 0.0f)", gt: "(%s > %s ? 255.0f : 0.0f)",
               le: "(%s <= %s ? 255.0f : 0.0f)", ge: "(%s >= %s ? 255.0f : 0.0f)",
               eq: "(%s == %s ? 255.0f : 0.0f)", ne: "(%s != %s ? 255.0f : 0.0f)",
               and: "float(int(%s) & int(%s))", or: "float(int(%s) | int(%s))",
               eor: "float(int(%s) ^ int(%s))" }.freeze
    COMPARE = %i[lt gt le ge eq ne].freeze
    BOOLEAN = %i[and or eor].freeze
    # libvips reads and gives angles in degrees.
    UNARY = { abs: "fabs(%s)", floor: "floor(%s)", ceil: "ceil(%s)", rint: "rint(%s)", exp: "exp(%s)",
              exp10: "exp10(%s)", log: "fs_log(%s)", log10: "fs_log10(%s)", tanh: "tanh(%s)",
              sinh: "sinh(%s)", cosh: "cosh(%s)", sin: "sin(%s * DEG)", cos: "cos(%s * DEG)",
              tan: "tan(%s * DEG)", asin: "(asin(%s) * RAD)", acos: "(acos(%s) * RAD)",
              atan: "(atan(%s) * RAD)" }.freeze
    KEEP_FORMAT = %i[abs floor ceil rint].freeze

    attr_reader :op, :args, :extra, :bands, :format, :width, :height, :interpretation

    def self.wrap(image)
      image.is_a?(Fused) ? image : leaf(image)
    end

    def self.leaf(image, memory: nil)
      new(:leaf, [], image: image, memory: memory, bands: image.bands, format: image.format, width: image.width,
                     height: image.height, interpretation: image.interpretation, meta: image)
    end

    # Fused images in a call's arguments, as libvips takes them.
    def self.unwrap(value)
      case value
      when Fused then value.vips
      when Array then value.map { |v| unwrap(v) }
      when Hash then value.transform_values { |v| unwrap(v) }
      else value
      end
    end

    def initialize(op, args, bands:, format:, width:, height:, interpretation: nil, extra: nil, image: nil,
                   memory: nil, meta: nil)
      @op = op
      @args = args
      @extra = extra
      @bands = bands
      @format = format
      @width = width
      @height = height
      @interpretation = interpretation
      @image = image
      @memory = memory
      @meta = meta
    end

    def +(other) = arithmetic(:add, other)
    def -(other) = arithmetic(:sub, other)
    def *(other) = arithmetic(:mul, other)
    def /(other) = arithmetic(:div, other)
    def **(other) = arithmetic(:pow, other)
    def -@ = arithmetic(:mul, -1)
    def <(other) = arithmetic(:lt, other)
    def >(other) = arithmetic(:gt, other)
    def <=(other) = arithmetic(:le, other)
    def >=(other) = arithmetic(:ge, other)
    def &(other) = arithmetic(:and, other)
    def |(other) = arithmetic(:or, other)
    def ^(other) = arithmetic(:eor, other)

    # As libvips has it: a test against each pixel, and never equal to nil.
    def ==(other)
      return false if other.nil?
      return equal?(other) unless operand?(other)

      arithmetic(:eq, other)
    end

    def !=(other)
      return true if other.nil?
      return !equal?(other) unless operand?(other)

      arithmetic(:ne, other)
    end

    UNARY.each_key { |name| define_method(name) { unary(name) } }

    def linear(a, b, **opts)
      return fallback(:linear, a, b, **opts) unless opts.empty?

      (self * a) + b
    end

    def ifthenelse(th, el, **opts)
      return fallback(:ifthenelse, th, el, **opts) unless opts.empty?

      given = [th, el]
      th = operand(th)
      el = operand(el)
      return fallback(:ifthenelse, *given) unless th && el && same_size?(th) && same_size?(el)

      match = [th, el, self].find { |x| x.is_a?(Fused) }
      th, el = [th, el].map { |x| x.is_a?(Const) ? cast_const(x, match.format) : x }
      formats = [th, el].map { |x| x.is_a?(Fused) ? x.format : match.format }
      bands = [self, th, el].map { |x| width_of(x, match) }.max
      node(:ite, [self, th, el], bands: bands, format: formats.max_by { |f| WIDER.index(f) || 0 })
    end

    def [](index)
      case index
      when Range then extract_band(index.begin, n: index.size)
      when Integer then extract_band(index)
      else fallback(:[], index)
      end
    end

    def extract_band(start, n: 1)
      return fallback(:extract_band, start, n: n) if start.negative? || start + n > bands

      node(:band, [self], bands: n, format: format, extra: [start, n])
    end

    def bandjoin(other)
      others = other.is_a?(Array) ? other : [other]
      parts = [self, *others].map { |x| x.is_a?(Numeric) ? Const.new([x.to_f]) : operand(x) }
      return fallback(:bandjoin, other) unless parts.all? && parts.all? { |p| p.is_a?(Const) || same_size?(p) }

      count = parts.sum { |p| p.is_a?(Const) ? p.values.size : p.bands }
      formats = parts.select { |p| p.is_a?(Fused) }.map(&:format)
      node(:join, parts, bands: count, format: formats.max_by { |f| WIDER.index(f) || 0 })
    end

    def bandmean
      return fallback(:bandmean) if INTS.include?(format)

      node(:mean, [self], bands: 1, format: format)
    end

    def cast(to, **opts)
      return fallback(:cast, to, **opts) unless opts.empty?
      return node(:alias, [self], bands: bands, format: to) unless RANGES.key?(to)

      node(:cast, [self], bands: bands, format: to, extra: RANGES.fetch(to))
    end

    # A table read at each pixel, from a table libvips holds: one row of
    # entries, a band for each output band or one for all.
    def maplut(lut, **opts)
      lut = lut.vips if lut.is_a?(Fused)
      usable = opts.empty? && INTS.include?(format) && lut.height == 1 &&
               (bands == 1 || lut.bands == 1 || lut.bands == bands)
      return fallback(:maplut, lut, **opts) unless usable

      values = lut.cast(:float).write_to_memory.unpack("f*")
      node(:lut, [self, Const.new(values)], bands: bands == 1 ? lut.bands : bands, format: lut.format,
                                            extra: [lut.width, lut.bands])
    end

    FLOATS = %i[float double].freeze

    # Blurred on the GPU with the mask libvips would use, edges carried out by
    # copying the outermost pixels as libvips does.
    def gaussblur(sigma, min_ampl: 0.2, precision: :integer, **opts)
      unless opts.empty? && FLOATS.include?(@format)
        return fallback(:gaussblur, sigma, min_ampl: min_ampl, precision: precision, **opts)
      end

      taps = taps_of(Vips::Image.gaussmat(sigma, min_ampl, separable: true, precision: precision))
      node(:conv, [self], bands: @bands, format: @format, extra: [taps, taps])
    end

    # A one row or one column mask on the GPU; anything else goes to libvips.
    def conv(mask, precision: :float, **opts)
      mask = mask.vips if mask.is_a?(Fused)
      line = mask.width == 1 || mask.height == 1
      usable = opts.empty? && precision == :float && line && FLOATS.include?(@format) && mask.get("offset").zero?
      return fallback(:conv, mask, precision: precision, **opts) unless usable

      taps = taps_of(mask)
      node(:conv, [self], bands: @bands, format: @format, extra: mask.height == 1 ? [taps, nil] : [nil, taps])
    end

    def copy(**opts)
      return fallback(:copy, **opts) unless opts.keys == [:interpretation]

      node(:alias, [self], bands: bands, format: format, interpretation: opts[:interpretation])
    end

    # Worked out and kept, as a start for whatever comes next.
    def copy_memory
      image = vips
      @memory ? self : Fused.leaf(image.copy_memory)
    end

    def leaf? = @op == :leaf
    def worked_out? = !@image.nil?

    # The pixels, as a Vips::Image. Worked out on the GPU the first time.
    def vips
      @image ||= work_out
    end

    def memory = @memory

    def inspect = "#<FilmScan::Fused #{@op} #{@width}x#{@height}x#{@bands} #{@format}>"
    alias to_s inspect

    def respond_to_missing?(name, include_private = false)
      vips_knows?(name) || super
    end

    # Anything else is libvips' to do, on the pixels as they stand.
    def method_missing(name, *args, **opts, &block)
      return super unless vips_knows?(name)

      fallback(name, *args, **opts, &block)
    end

    private

    # A method of Vips::Image's own, or an operation it calls by name.
    def vips_knows?(name)
      Vips::Image.method_defined?(name) || Vips.type_find("VipsOperation", name.to_s) != 0
    end

    def fallback(name, *args, **opts, &block)
      result = vips.public_send(name, *Fused.unwrap(args.map { |a| raw(a) }), **Fused.unwrap(opts), &block)
      result.is_a?(Vips::Image) ? Fused.leaf(result) : result
    end

    def taps_of(mask)
      scale = mask.get("scale")
      mask.cast(:double).write_to_memory.unpack("d*").map { |v| v / scale }
    end

    def raw(value)
      return value unless value.is_a?(Const)

      value.values.size == 1 ? value.values.first : value.values
    end

    def node(op, args, bands:, format:, extra: nil, interpretation: @interpretation)
      Fused.new(op, args, bands: bands, format: format, width: @width, height: @height,
                          interpretation: interpretation, extra: extra, meta: @meta)
    end

    def operand?(value)
      value.is_a?(Numeric) || value.is_a?(Fused) || value.is_a?(Vips::Image) ||
        (value.is_a?(Array) && !value.empty? && value.all?(Numeric))
    end

    # A constant, an image of either kind, or nil for what cannot be one.
    def operand(value)
      case value
      when Fused then value
      when Vips::Image then Fused.leaf(value)
      when Numeric then Const.new([value.to_f])
      when Array then value.all?(Numeric) && !value.empty? ? Const.new(value.map(&:to_f)) : nil
      end
    end

    def same_size?(other)
      !other.is_a?(Fused) || (other.width == @width && other.height == @height)
    end

    def width_of(x, match)
      case x
      when Fused then x.bands
      else x.values.size == 1 ? match.bands : x.values.size
      end
    end

    # ruby-vips gives a constant the format of the image beside it, so a
    # fraction set against a mask is a whole number by the time it is used.
    def cast_const(const, to)
      return const unless RANGES.key?(to)

      lo, hi = RANGES.fetch(to)
      Const.new(const.values.map { |v| v.truncate.clamp(lo, hi).to_f })
    end

    def arithmetic(op, value)
      other = operand(value)
      return fallback(VIPS_NAMES.fetch(op), value) unless other && same_size?(other)

      # ruby-vips divides by a constant as a multiply by its reciprocal.
      if op == :div && other.is_a?(Const)
        op = :mul
        other = Const.new(other.values.map { |v| 1.0 / v })
      end
      bands = [@bands, other.is_a?(Const) ? other.values.size : other.bands].max
      if other.is_a?(Fused) && ![1, bands].include?(other.bands) || ![1, bands].include?(@bands)
        return fallback(VIPS_NAMES.fetch(op), other)
      end

      node(:binary, [self, other], bands: bands, format: format_of(op, other), extra: op)
    end

    VIPS_NAMES = { add: :+, sub: :-, mul: :*, div: :/, pow: :**, lt: :<, gt: :>, le: :<=, ge: :>=, eq: :==,
                   ne: :!=, and: :&, or: :|, eor: :^ }.freeze

    def format_of(op, other)
      return :uchar if COMPARE.include?(op)

      formats = [@format, other.is_a?(Fused) ? other.format : nil].compact
      if BOOLEAN.include?(op)
        return other.is_a?(Fused) && formats.all?(:uchar) ? :uchar : :int
      end
      return :double if formats.include?(:double)
      return :float if formats.include?(:float) || other.is_a?(Const) || %i[div pow].include?(op)

      formats.all?(:uchar) ? { add: :ushort, sub: :short, mul: :ushort }.fetch(op, :int) : :int
    end

    def unary(name)
      to = if KEEP_FORMAT.include?(name) then @format
           else @format == :double ? :double : :float
           end
      node(:unary, [self], bands: @bands, format: to, extra: name)
    end

    def work_out
      return convolve if @op == :conv

      kernel = Source.new(self)
      return settle_inputs_then_work_out if kernel.inputs.size > MAX_INPUTS

      bytes = @width * @height * @bands * 4
      out = Metal.alloc(bytes)
      Metal.run(kernel.source, kernel.inputs.map(&:input), kernel.constants, out, @width * @height)
      @memory = out
      image = Vips::Image.new_from_memory(out, @width, @height, @bands, :float)
      image = image.cast(@format) if RANGES.key?(@format)
      described(image)
    end

    # Across, then down, each a pass of its own on the GPU.
    def convolve
      source = Input.new(@args[0])
      data = source.input
      bytes = @width * @height * @bands * 4
      out = nil
      @extra.each_with_index do |taps, axis|
        next unless taps

        out = Metal.alloc(bytes)
        Metal.run(Conv.source(@bands, axis), [data], [@width, @height, taps.size, *taps], out, @width * @height)
        data = [out, out.size, true]
      end
      @memory = out
      image = Vips::Image.new_from_memory(out, @width, @height, @bands, :float)
      described(image)
    end

    # The kernel for one pass of a convolution, read with each edge pixel
    # carried outward.
    module Conv
      def self.source(bands, axis)
        at = axis.zero? ? "clamp(x + t - r, 0, w - 1) + y * w" : "x + clamp(y + t - r, 0, h - 1) * w"
        <<~METAL
          #include <metal_stdlib>
          using namespace metal;
          kernel void fused(device const float* x0 [[buffer(0)]], device const float* k [[buffer(1)]],
                            device float* o [[buffer(2)]], constant uint& n [[buffer(3)]],
                            uint i [[thread_position_in_grid]]) {
            if (i >= n) return;
            int w = int(k[0]);
            int h = int(k[1]);
            int taps = int(k[2]);
            int r = taps / 2;
            int x = int(i % uint(w));
            int y = int(i / uint(w));
            float s[#{bands}];
            for (int b = 0; b < #{bands}; b++) s[b] = 0.0f;
            for (int t = 0; t < taps; t++) {
              float c = k[3 + t];
              int p = #{at};
              for (int b = 0; b < #{bands}; b++) s[b] += c * x0[p * #{bands} + b];
            }
            for (int b = 0; b < #{bands}; b++) o[i * #{bands} + b] = s[b];
          }
        METAL
      end
    end

    # Fields libvips keeps for itself, or sets from the pixels.
    HEADER = %w[width height bands format coding interpretation xoffset yoffset xres yres filename].freeze

    # The pixels with what libvips would have carried along with them: the
    # header and metadata of the first image they came from, so a frame keeps
    # its orientation, resolution and profile.
    def described(image)
      return @interpretation ? image.copy(interpretation: @interpretation) : image unless @meta

      image = image.copy(interpretation: @interpretation || image.interpretation, xres: @meta.xres, yres: @meta.yres)
      fields = @meta.get_fields.reject { |name| HEADER.include?(name) || name.start_with?("vips-") }
      return image if fields.empty?

      image.mutate { |m| fields.each { |name| m.set_type!(@meta.get_typeof(name), name, @meta.get(name)) } }
    end

    # Too many images for one kernel: each argument is worked out on its own
    # first, which leaves this one with fewer.
    def settle_inputs_then_work_out
      @args.each { |a| a.vips if a.is_a?(Fused) }
      work_out
    end

    # An image a kernel reads: the GPU's own memory where it wrote it, or a
    # float copy from libvips.
    class Input
      attr_reader :node

      def initialize(node)
        @node = node
      end

      def input
        return [@node.memory, @node.memory.size, true] if @node.memory

        @held = @node.vips.cast(:float).copy_memory
        pointer = Metal::Libvips.vips_image_get_data(@held)
        raise "libvips gave no pixels for #{@node.inspect}" if pointer.null?

        [pointer, @node.width * @node.height * @node.bands * 4, false]
      end
    end

    # The Metal source for one expression, its inputs and its constants.
    class Source
      attr_reader :inputs, :constants, :source

      def initialize(root)
        @root = root
        @inputs = []
        @input_index = {}.compare_by_identity
        @constants = []
        @constant_at = {}.compare_by_identity
        @names = {}.compare_by_identity
        @lines = []
        @count = 0
        out = names(root)
        @source = assemble(out)
      end

      private

      def assemble(out)
        params = @inputs.each_index.map { |i| "device const float* x#{i} [[buffer(#{i})]]," }
        n = @inputs.size
        stores = out.each_with_index.map { |v, c| "  o[i * #{@root.bands} + #{c}] = #{v};" }
        <<~METAL
          #include <metal_stdlib>
          using namespace metal;
          constant float DEG = 0.017453292519943295f;
          constant float RAD = 57.29577951308232f;
          inline float fs_div(float a, float b) { return b == 0.0f ? 0.0f : a / b; }
          inline float fs_log(float a) { return a == 0.0f ? 0.0f : log(a); }
          inline float fs_log10(float a) { return a == 0.0f ? 0.0f : log10(a); }
          inline float fs_pow(float a, float e) {
            if (a == 0.0f && e < 0.0f) return 0.0f;
            if (a < 0.0f && e == rint(e)) {
              float m = pow(-a, e);
              return fmod(fabs(e), 2.0f) == 1.0f ? -m : m;
            }
            return pow(a, e);
          }
          inline float fs_cast(float a, float lo, float hi) { return clamp(trunc(a), lo, hi); }
          kernel void fused(#{params.join(' ')}
                            device const float* k [[buffer(#{n})]],
                            device float* o [[buffer(#{n + 1})]],
                            constant uint& n [[buffer(#{n + 2})]],
                            uint i [[thread_position_in_grid]]) {
            if (i >= n) return;
          #{@lines.join("\n")}
          #{stores.join("\n")}
          }
        METAL
      end

      def fresh(expression)
        name = "v#{@count += 1}"
        @lines << "  float #{name} = #{expression};"
        name
      end

      def constant(const)
        @constant_at[const] ||= begin
          at = @constants.size
          @constants.concat(const.values)
          at
        end
      end

      # The variable names holding each band of `x`, `bands` wide.
      def operand(x, bands)
        if x.is_a?(Const)
          at = constant(x)
          return Array.new(bands) { |c| "k[#{at + (x.values.size == 1 ? 0 : c)}]" }
        end
        own = names(x)
        own.size == 1 ? Array.new(bands, own.first) : own
      end

      def names(x)
        @names[x] ||= x.worked_out? || x.leaf? || x.op == :conv ? load(x) : build(x)
      end

      # One input for each image, however many starts were made from it.
      def load(x)
        i = (@input_index[x.memory || x.vips] ||= (@inputs << Input.new(x)).size - 1)
        Array.new(x.bands) { |c| fresh("x#{i}[i * #{x.bands} + #{c}]") }
      end

      def build(x)
        case x.op
        when :alias then names(x.args[0])
        when :binary
          a, b = x.args.map { |v| operand(v, x.bands) }
          a.zip(b).map { |l, r| fresh(format(BINARY.fetch(x.extra), l, r)) }
        when :unary then names(x.args[0]).map { |v| fresh(format(UNARY.fetch(x.extra), v)) }
        when :ite
          c, t, e = x.args.map { |v| operand(v, x.bands) }
          c.zip(t, e).map { |p, l, r| fresh("(#{p} != 0.0f ? #{l} : #{r})") }
        when :band then names(x.args[0])[x.extra[0], x.extra[1]]
        when :join then x.args.flat_map { |v| v.is_a?(Const) ? operand(v, v.values.size) : names(v) }
        when :mean
          own = names(x.args[0])
          [fresh("((#{own.join(' + ')}) / #{own.size}.0f)")]
        when :cast
          lo, hi = x.extra
          names(x.args[0]).map { |v| fresh("fs_cast(#{v}, #{lo}.0f, #{hi}.0f)") }
        when :lut then lut(x)
        else raise "no kernel for #{x.op}"
        end
      end

      def lut(x)
        index, table = x.args
        size, lut_bands = x.extra
        at = constant(table)
        own = names(index)
        Array.new(x.bands) do |c|
          v = own.size == 1 ? own.first : own[c]
          band = lut_bands == 1 ? 0 : c
          fresh("k[#{at} + clamp(int(#{v}), 0, #{size - 1}) * #{lut_bands} + #{band}]")
        end
      end
    end
    private_constant :Source, :Input

    # Fused images on the right of a libvips image's arithmetic, or among the
    # images of a call, which libvips itself could not take.
    module ImageInterop
      %i[+ - * / ** < > <= >= & | ^].each do |name|
        define_method(name) do |other|
          other.is_a?(Fused) ? Fused.leaf(self).public_send(name, other) : super(other)
        end
      end

      def ==(other)
        other.is_a?(Fused) ? Fused.leaf(self) == other : super
      end

      def !=(other)
        other.is_a?(Fused) ? Fused.leaf(self) != other : super
      end

      def ifthenelse(th, el, **opts)
        return Fused.leaf(self).ifthenelse(th, el) if opts.empty? && (th.is_a?(Fused) || el.is_a?(Fused))

        super(*Fused.unwrap([th, el]), **opts)
      end

      def bandjoin(other)
        others = other.is_a?(Array) ? other : [other]
        others.any?(Fused) ? Fused.leaf(self).bandjoin(others) : super
      end
    end

    module OperationInterop
      def call(name, supplied, optional = {}, option_string = "")
        super(name, Fused.unwrap(supplied), Fused.unwrap(optional), option_string)
      end
    end

    # Taught once, when --engine apple first runs.
    def self.teach_vips
      return if @taught

      Vips::Image.prepend(ImageInterop)
      Vips::Operation.singleton_class.prepend(OperationInterop)
      @taught = true
    end
  end
end
