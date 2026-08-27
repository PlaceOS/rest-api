require "json"

module PlaceOS::Api::ImageGen
  # Turns a brief, the domain's brand kit and a refine chain into the text a
  # vendor is sent.
  #
  # The words on a finished poster are drawn by the browser on a text layer, not
  # by the model, so unless the caller opts out the prompt asks for a clear area
  # and for no lettering at all. The logo is composited from the customer's own
  # file for the same reason, so the prompt asks for room rather than a drawing
  # of it.
  module Prompt
    # `signage_ai` metadata on the org zone
    struct BrandKit
      include JSON::Serializable

      getter organisation : String? = nil
      getter palette : Hash(String, String)? = nil
      getter tone : String? = nil
      getter logo_upload_id : String? = nil
      getter never_include : Array(String) = [] of String

      @[JSON::Field(ignore: true)]
      getter font : JSON::Any? = nil

      def initialize
      end

      def self.parse(value : JSON::Any?) : BrandKit?
        return nil unless value
        BrandKit.from_json(value.to_json)
      rescue JSON::SerializableError | JSON::ParseException
        nil
      end

      def palette_line : String?
        colours = palette
        return nil if colours.nil? || colours.empty?
        colours.map { |name, hex| "#{name} #{hex}" }.join(", ")
      end
    end

    # Where the browser will put things, so the model leaves room.
    enum TextMode
      # the app draws the words (default)
      Layer
      # the caller asked the model to render the words itself
      Model
    end

    record Options,
      brief : String,
      aspect : String,
      text_mode : TextMode = TextMode::Layer,
      include_logo : Bool = true,
      brand : BrandKit? = nil,
      words : String? = nil,
      history : Array(String) = [] of String,
      instruction : String? = nil

    def self.build(options : Options) : String
      lines = [] of String

      if (brand = options.brand)
        parts = [] of String
        parts << "Organisation: #{brand.organisation}." if brand.organisation.presence
        if (colours = brand.palette_line)
          parts << "Palette: #{colours}."
        end
        parts << "Tone: #{brand.tone}." if brand.tone.presence
        lines << "Brand: #{parts.join(" ")}" unless parts.empty?
      end

      lines << "Layout: #{layout_line(options)}"
      lines << "Brief: #{options.brief}" if options.brief.presence

      options.history.each_with_index do |entry, index|
        lines << "Change #{index + 1}: #{entry}"
      end

      if (instruction = options.instruction) && instruction.presence
        lines << "Change #{options.history.size + 1}: #{instruction}"
        lines << "Keep everything else exactly as it is."
      end

      if (brand = options.brand) && !brand.never_include.empty?
        lines << "Never include: #{brand.never_include.join(", ")}."
      end

      lines.join("\n")
    end

    private def self.layout_line(options : Options) : String
      orientation = case options.aspect
                    when "9:16" then "Portrait"
                    when "1:1"  then "Square"
                    else             "Landscape"
                    end

      parts = ["#{orientation} #{options.aspect} poster background for a digital signage screen."]

      case options.text_mode
      in TextMode::Layer
        parts << "Leave the top third clear and plain so a headline can be added over it."
        parts << "Leave a clear area in the bottom right corner for a logo." if options.include_logo
        parts << "Do not render any text, letters, numbers, words or logos anywhere in the image."
      in TextMode::Model
        if (words = options.words) && words.presence
          parts << "Render exactly this text and nothing else: #{words.inspect}."
        end
        parts << "Leave a clear area in the bottom right corner for a logo." if options.include_logo
      end

      parts.join(" ")
    end
  end
end
