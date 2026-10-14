require "digest"
require "fileutils"

module FilmScan
  # Finds frames that look the wrong way up, with a small pretrained network
  # that tells which of four ways a photograph was turned. It only suggests.
  # A frame is sure when the network says the same however the frame is
  # turned first, the lab left it untagged, and the suggestion turns it the
  # way the roll's other portraits go. Anything else it flags is for a look
  # by eye.
  #
  # The network is DuarteBarbosa/deep-image-orientation-detection v2, under
  # the MIT licence, downloaded once into the cache folder and checked
  # against its digest. It runs through the onnxruntime gem, which is only
  # needed for this.
  class OrientationCheck
    MODEL_NAME = "orientation_model_v2_0.9882.onnx"
    MODEL_URL = "https://huggingface.co/DuarteBarbosa/deep-image-orientation-detection/resolve/" \
                "9bc7687b9fd5152e220084ca23e13e7fa1daec38/#{MODEL_NAME}".freeze
    MODEL_SHA256 = "cffe911c1dff47fbfbbd90110aaab9c07134645c460d35b3ae8832079bea91ba".freeze
    MODEL_MB = 81

    # What the network reads, as it was trained: squashed to a square, the
    # middle cut out, in ImageNet's mean and spread.
    SQUASH = 416
    SIZE = 384
    MEAN = [0.485, 0.456, 0.406].freeze
    STD = [0.229, 0.224, 0.225].freeze

    # The network's four classes, as the clockwise turn the picture was given.
    TURNS = [0, 270, 180, 90].freeze

    # The clockwise turn each orientation gives a frame when it is written.
    TAG_TURN = { 1 => 0, 6 => 90, 3 => 180, 8 => 270 }.freeze

    # Read from a copy this wide, well over what the network takes in.
    WIDTH = 512

    # Portrait frames a roll needs before the way it turns them counts.
    HABIT_FRAMES = 3

    Finding = Data.define(:path, :written, :suggested, :sure, :why) do
      def stem
        File.basename(path, ".*")
      end
    end

    # `predict` takes a frame and returns the network's four probabilities,
    # and is only given in place of the network by the tests.
    def initialize(predict = nil, log: $stdout)
      @predict = predict || method(:network)
      @log = log
    end

    # What the check found in `paths`, frames of the roll whose frames are
    # `roll`: a Finding for each frame the network says is turned.
    def check(paths, roll: paths)
      usual = habit(roll)
      paths.each_with_index.filter_map do |path, i|
        @log.print "\r  checking #{i + 1}/#{paths.size}"
        turn = turned(written(path))
        turn && finding(path, turn, usual)
      end
    ensure
      @log.puts
    end

    # The clockwise turn the frame as written seems to have been given, when
    # the network says so at every turn of it, and nil otherwise.
    def turned(image)
      first = call(image)
      return nil if first.zero?

      agree = { 90 => :d90, 180 => :d180, 270 => :d270 }.all? do |turn, rot|
        (call(image.rot(rot)) - turn) % 360 == first
      end
      agree ? first : nil
    end

    # The way the roll's portraits are turned, when enough of them say so.
    def habit(paths)
      portraits = paths.map { Orientation.of(_1) }.select { [6, 8].include?(_1) }
      return nil if portraits.size < HABIT_FRAMES

      portraits.tally.max_by { _2 }[0]
    end

    # Overrides to paste in for the sure frames, the rest commented out with
    # the reason each needs a look first.
    def report(findings, checked)
      return "all #{checked} frames look the right way up" if findings.empty?

      sure, unsure = findings.partition(&:sure)
      lines = []
      lines << "# #{sure.size} of #{checked} frames look turned and the check is sure of them:" if sure.any?
      sure.each { |f| lines << "\"#{f.stem}\": { orientation: #{f.suggested} }  # #{f.why}" }
      lines << "# #{unsure.size} more look turned; check these by eye first:" if unsure.any?
      unsure.each { |f| lines << "# \"#{f.stem}\": { orientation: #{f.suggested} }  # #{f.why}" }
      lines.join("\n")
    end

    # The network, downloaded the first time and checked against its digest
    # every time. FILM_SCAN_ORIENTATION_MODEL names a copy kept elsewhere.
    def self.model_path(log: $stdout)
      path = ENV.fetch("FILM_SCAN_ORIENTATION_MODEL") { File.join(cache_dir, MODEL_NAME) }
      unless File.exist?(path)
        log.puts "fetching the orientation model (#{MODEL_MB} MB, once) into #{File.dirname(path)}..."
        download(MODEL_URL, path)
      end
      raise ArgumentError, "#{path} is not the orientation model this expects" unless digest(path) == MODEL_SHA256

      path
    end

    def self.cache_dir
      base = ENV["XDG_CACHE_HOME"].to_s
      base = File.join(Dir.home, ".cache") if base.empty?
      File.join(base, "film_scan", "models")
    end

    def self.digest(path)
      Digest::SHA256.file(path).hexdigest
    end

    # Fetched under a temporary name and kept only when its digest is right.
    def self.download(url, path, redirects = 5)
      require "net/http"
      FileUtils.mkdir_p(File.dirname(path))
      partial = "#{path}.partial"
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          case response
          when Net::HTTPRedirection
            raise "too many redirects fetching the orientation model" if redirects.zero?

            return download(URI.join(url, response["location"]).to_s, path, redirects - 1)
          when Net::HTTPSuccess
            File.open(partial, "wb") { |file| response.read_body { |chunk| file.write(chunk) } }
          else
            raise "could not fetch the orientation model: #{response.code} #{response.message}"
          end
        end
      end
      raise "the orientation model came down damaged; try again" unless digest(partial) == MODEL_SHA256

      File.rename(partial, path)
      path
    ensure
      File.delete(partial) if partial && File.exist?(partial)
    end

    private

    # A frame as it will be written, small, in memory since the network reads
    # it four times.
    def written(path)
      image = Orientation.thumbnail(path, WIDTH).copy_memory
      image = image.bandjoin([image, image]) if image.bands == 1
      image = image[0..2] if image.bands > 3
      image.cast(:float) / (image.format == :ushort ? 65535.0 : 255.0)
    end

    def call(image)
      odds = @predict.call(image)
      TURNS[odds.each_with_index.max_by(&:first)[1]]
    end

    def finding(path, turn, usual)
      written = Orientation.of(path)
      suggested = TAG_TURN.key((TAG_TURN.fetch(written) - turn) % 360)
      why, sure = if Orientation.overrides.key?(path)
                    ["it already has an override of #{written}", false]
                  elsif written != 1
                    ["the lab tagged it #{written}", false]
                  elsif usual.nil?
                    ["untagged, and the roll has too few portraits to say which way they go", false]
                  elsif suggested != usual
                    ["untagged, but the roll's portraits go #{usual}", false]
                  else
                    ["untagged, and the roll's portraits go #{usual}", true]
                  end
      Finding.new(path: path, written: written, suggested: suggested, sure: sure, why: why)
    end

    def network(image)
      @model ||= load_model
      planes = image.resize(SQUASH.to_f / image.width, vscale: SQUASH.to_f / image.height, kernel: :linear)
                    .extract_area((SQUASH - SIZE) / 2, (SQUASH - SIZE) / 2, SIZE, SIZE)
      tensor = (0..2).map do |c|
        ((planes[c] - MEAN[c]) / STD[c]).cast(:float).write_to_memory.unpack("e*").each_slice(SIZE).to_a
      end
      logits = @model.predict({ @model.inputs.first[:name] => [tensor] }).values.first.first
      top = logits.max
      odds = logits.map { Math.exp(_1 - top) }
      odds.map { _1 / odds.sum }
    end

    def load_model
      begin
        require "onnxruntime"
      rescue LoadError
        raise ArgumentError, "--orient needs the onnxruntime gem: gem install onnxruntime, or under " \
                             "bundle exec, bundle config set --local with orient and then bundle install"
      end
      OnnxRuntime::Model.new(self.class.model_path(log: @log), intra_op_num_threads: Vips.concurrency,
                                                               inter_op_num_threads: 1)
    end
  end
end
