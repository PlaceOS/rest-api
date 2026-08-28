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
    # Art direction sent ahead of every brief.
    #
    # Image models left to themselves produce a recognisable house style:
    # centred title over a purple gradient, glowing orbs, floating geometry.
    # This is the counter-brief, and it is the largest single part of the
    # prompt, so it is kept here rather than buried in a method.
    #
    # Split because most of it applies whatever draws the words, but a few
    # lines only make sense when the model is setting the type. When the app
    # composites the headline afterwards the model is producing a background,
    # and telling it to art direct typography or to avoid "text over a generic
    # background" argues with the layout instruction that follows.
    STYLE_OPENING = <<-TEXT
      Avoid the generic "AI-generated poster" aesthetic.
      Design this as if it were created by an experienced human graphic designer working from a real creative brief, not generated from a text prompt.
      TEXT

    STYLE_REQUIREMENTS = <<-TEXT
      STYLE REQUIREMENTS:
      - Use deliberate, editorial graphic design with a clear visual concept.
      - Prioritise composition, spacing, hierarchy and art direction over decorative effects.
      - Make the layout feel designed rather than algorithmically balanced.
      - Allow asymmetry, negative space, unusual cropping, restrained layouts and imperfect/off-centre placement where appropriate.
      - Use a limited, intentional colour palette.
      - Aim for the quality of a professionally commissioned event poster, cultural institution campaign, design studio project, magazine advertisement or high-end printed flyer.
      - The finished piece should feel plausible as real-world graphic design.
      TEXT

    # only when the model is setting the type
    STYLE_TYPOGRAPHY = <<-TEXT
      - Prioritise strong typography alongside composition and hierarchy.
      - Typography should feel professionally art-directed and appropriate to the subject.
      - Use no more typefaces, weights or text effects than a competent designer would realistically choose.
      - Treat photography/illustration as an integrated part of the composition rather than placing text over a generic background.
      TEXT

    STYLE_AVOID = <<-TEXT
      AVOID:
      - generic AI poster aesthetics
      - default futuristic/corporate styling
      - purple-blue-orange gradients unless specifically requested
      - glowing neon edges
      - glowing blobs or orbs
      - random floating geometric shapes
      - abstract 3D objects added only to fill space
      - excessive glassmorphism
      - unnecessary lens flares or bloom
      - generic particle effects
      - holographic effects
      - fake depth-of-field added to graphic design
      - huge centred title + subtitle + button style layouts
      - perfectly symmetrical compositions unless the concept calls for it
      - generic vector people or corporate illustrations
      - arbitrary decorative squiggles
      - excessive rounded rectangles
      - random badges, pills or UI components
      - meaningless microtext
      - fake logos
      - pseudo-technical markings
      - ornamental elements without a clear design purpose
      - overly polished "concept art" rendering
      - the appearance of a Canva template
      - the appearance of a cryptocurrency, SaaS, Web3 or AI conference poster unless specifically requested
      - visual clutter added merely to make the design seem sophisticated
      TEXT

    STYLE_CLOSING = <<-TEXT
      IMPORTANT:
      Do not interpret "professional" as "futuristic", "glossy", "minimal corporate", or "luxury gradient".
      Before designing, infer an appropriate real-world graphic-design direction from the subject matter. Establish a specific visual idea and let that idea determine the typography, image treatment, composition and colour palette.
      The design should have character and specificity. It should look like somebody made actual aesthetic decisions.
      Do not add text, icons, graphics, logos, dates, URLs, QR codes or decorative elements that were not requested.
      TEXT

    # only when the model is setting the type: there is no supplied wording to
    # reproduce when the app draws it afterwards
    STYLE_TEXT_FIDELITY = <<-TEXT
      For any required text, reproduce the supplied wording exactly. Do not paraphrase it, invent additional copy, or fill empty areas with placeholder text.
      TEXT

    def self.style(text_mode : TextMode) : String
      sections = [STYLE_OPENING] of String

      requirements = STYLE_REQUIREMENTS
      requirements = "#{requirements}\n#{STYLE_TYPOGRAPHY}" if text_mode.model?
      sections << requirements

      sections << STYLE_AVOID
      sections << STYLE_CLOSING
      sections << STYLE_TEXT_FIDELITY if text_mode.model?

      sections.join("\n")
    end

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
      kind : Kind = Kind::Generate,
      text_mode : TextMode = TextMode::Layer,
      include_logo : Bool = true,
      brand : BrandKit? = nil,
      words : String? = nil,
      history : Array(String) = [] of String,
      instruction : String? = nil,
      # how many images the person attached, so the brief can name them
      references : Int32 = 0

    # What an edit is told, in place of the art direction and the layout brief.
    #
    # gpt-image-2 regenerates the whole frame rather than painting into a
    # region, so an edit drifts unless it is held down hard. The generation
    # style block makes that worse: it asks the model to establish a visual
    # idea and let it "determine the typography, image treatment, composition
    # and colour palette", which is a redesign brief. None of it is sent here.
    EDIT_PRESERVATION = <<-TEXT
      Edit the supplied image. Make only the change described below and leave everything else untouched.
      Preserve exactly, unless the change itself requires otherwise:
      - the existing layout, composition, framing and crop
      - every colour, including backgrounds, fills and accents
      - every typeface, weight, size, casing and text position
      - all other text, word for word, including any wording you would consider a placeholder
      - all existing photography, illustration, logos and graphic elements
      Do not redesign, restyle, recolour, re-typeset, re-crop or re-compose the image.
      Do not "improve" anything that was not part of the change.
      Do not add text, graphics or decoration that was not asked for.
      The result should look like the supplied image with one alteration made to it, not like a new design of the same subject.
      TEXT

    # What "image 2" in a brief means.
    #
    # The vendor is handed a list of images with no names, so a brief that says
    # "the person in image 2" is meaningless unless the order is spelled out.
    # On an edit the image being changed is sent first, which would make the
    # person's first reference image 2 if that went unsaid.
    def self.references_line(count : Int32, editing : Bool) : String?
      return nil if count < 1
      lines = [] of String
      if editing
        lines << "The first attached image is the image being edited."
        lines << "The #{count} image(s) after it were supplied with this request, numbered 1 to #{count} in that order."
      else
        lines << "#{count} image(s) are attached with this request, numbered 1 to #{count} in the order they are sent."
      end
      lines << %(Where the wording says "image 1", "image 2" and so on, it means those.)
      lines << "Use each one as the wording asks: as a guide to style, or as something to include in the picture."
      lines << "Do not reproduce an attached image as the whole poster unless asked to, and do not copy any lettering from one."
      lines.join(" ")
    end

    def self.build(options : Options) : String
      return build_edit(options) if options.kind.edit?

      lines = [] of String

      lines << style(options.text_mode)

      if (attached = references_line(options.references, false))
        lines << attached
      end

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

    private def self.build_edit(options : Options) : String
      lines = [EDIT_PRESERVATION] of String

      if (attached = references_line(options.references, true))
        lines << attached
      end

      # what the poster was originally for, so a change is read in context
      lines << "The image is a #{options.aspect} poster for a digital signage screen."
      lines << "It was made for this brief: #{options.brief}" if options.brief.presence

      options.history.each_with_index do |entry, index|
        lines << "Change #{index + 1}, already applied: #{entry}"
      end

      if (instruction = options.instruction) && instruction.presence
        lines << "The change to make now, and the only one: #{instruction}"
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

      parts = [] of String

      case options.text_mode
      in TextMode::Layer
        # the app draws the words over the top, so the model is asked for a
        # background and told to keep the lettering out of it
        parts << "#{orientation} #{options.aspect} poster background for a digital signage screen."
        parts << "Leave the top third clear and plain so a headline can be added over it."
        parts << "Leave a clear area in the bottom right corner for a logo." if options.include_logo
        parts << "Do not render any text, letters, numbers, words or logos anywhere in the image."
      in TextMode::Model
        # the caller opted out of the text layer, so the model has to produce a
        # finished poster. Without this it is asked for a background and answers
        # with one, and the words never appear.
        parts << "#{orientation} #{options.aspect} poster for a digital signage screen."
        if (words = options.words) && words.presence
          parts << "Render exactly this text, spelt correctly and large enough to read across a room: #{words.inspect}."
        else
          parts << "Render the wording from the brief as part of the poster, spelt correctly and large enough to read across a room."
        end
        parts << "Leave a clear area in the bottom right corner for a logo." if options.include_logo
      end

      parts.join(" ")
    end
  end
end
