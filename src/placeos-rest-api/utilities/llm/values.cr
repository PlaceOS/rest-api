module PlaceOS::Api::Llm
  # Syntax checks for the values an op may carry, the same rules as
  # `value-syntax.ts`, `sanitise.ts` and `path-data.ts` in libs/map-editor.
  # The editor re-checks everything with the live document; a value refused
  # here is reported on the op so the editor can show it unchecked.
  module Values
    NAMED_COLOURS = Set{
      "aliceblue", "antiquewhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black",
      "blanchedalmond", "blue", "blueviolet", "brown", "burlywood", "cadetblue", "chartreuse",
      "chocolate", "coral", "cornflowerblue", "cornsilk", "crimson", "cyan", "darkblue", "darkcyan",
      "darkgoldenrod", "darkgray", "darkgreen", "darkgrey", "darkkhaki", "darkmagenta",
      "darkolivegreen", "darkorange", "darkorchid", "darkred", "darksalmon", "darkseagreen",
      "darkslateblue", "darkslategray", "darkslategrey", "darkturquoise", "darkviolet", "deeppink",
      "deepskyblue", "dimgray", "dimgrey", "dodgerblue", "firebrick", "floralwhite", "forestgreen",
      "fuchsia", "gainsboro", "ghostwhite", "gold", "goldenrod", "gray", "green", "greenyellow",
      "grey", "honeydew", "hotpink", "indianred", "indigo", "ivory", "khaki", "lavender",
      "lavenderblush", "lawngreen", "lemonchiffon", "lightblue", "lightcoral", "lightcyan",
      "lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey", "lightpink", "lightsalmon",
      "lightseagreen", "lightskyblue", "lightslategray", "lightslategrey", "lightsteelblue",
      "lightyellow", "lime", "limegreen", "linen", "magenta", "maroon", "mediumaquamarine",
      "mediumblue", "mediumorchid", "mediumpurple", "mediumseagreen", "mediumslateblue",
      "mediumspringgreen", "mediumturquoise", "mediumvioletred", "midnightblue", "mintcream",
      "mistyrose", "moccasin", "navajowhite", "navy", "oldlace", "olive", "olivedrab", "orange",
      "orangered", "orchid", "palegoldenrod", "palegreen", "paleturquoise", "palevioletred",
      "papayawhip", "peachpuff", "peru", "pink", "plum", "powderblue", "purple", "rebeccapurple",
      "red", "rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown", "seagreen", "seashell",
      "sienna", "silver", "skyblue", "slateblue", "slategray", "slategrey", "snow", "springgreen",
      "steelblue", "tan", "teal", "thistle", "tomato", "turquoise", "violet", "wheat", "white",
      "whitesmoke", "yellow", "yellowgreen", "none", "transparent", "currentcolor", "inherit",
    }

    HEX_COLOUR      = /\A#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})\z/i
    FUNCTION_COLOUR = /\A(?:rgba?|hsla?)\(\s*[\d.%-]+\s*[,\s]\s*[\d.%-]+\s*[,\s]\s*[\d.%-]+\s*(?:[,\/]\s*[\d.%]+\s*)?\)\z/i
    FRAGMENT_PAINT  = /\Aurl\(\s*['"]?#[A-Za-z][A-Za-z0-9_.-]*['"]?\s*\)(?:\s+(?:none|#[0-9a-f]{3,8}|[a-z]+))?\z/i
    NUMBER          = /\A[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/
    LENGTH          = /\A[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?(?:px|pt|pc|mm|cm|in|em|rem|ex|%)?\z/
    PERCENTAGE      = /\A\d+(?:\.\d+)?%\z/
    CLASS_TOKEN     = /\A-?[A-Za-z_][A-Za-z0-9_-]*\z/
    FONT_WEIGHT     = /\A(?:normal|bold|bolder|lighter|[1-9]00)\z/
    UNSAFE_TEXT     = /url\(|expression\(|behavior:|javascript:|<|>|[\r\n]/i

    # `sanitise.ts` UNSAFE_CSS_VALUE plus a backslash: browsers decode CSS
    # escapes (`u\72l(`), so escaped text cannot be matched literally
    UNSAFE_CSS = /expression\s*\(|behavior\s*:|javascript\s*:|url\s*\(\s*(?!['"]?#)|\\/i

    # a `url(` that does not point at a fragment of the document
    EXTERNAL_URL = /url\s*\(\s*['"]?(?!#)/i

    PATH_TOKEN = /[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/
    PATH_ARITY = {'M' => 2, 'L' => 2, 'H' => 1, 'V' => 1, 'C' => 6, 'S' => 4, 'Q' => 4, 'T' => 2, 'A' => 7, 'Z' => 0}

    def self.unsafe_css?(text : String) : Bool
      !UNSAFE_CSS.match(text).nil?
    end

    def self.external_url?(text : String) : Bool
      !EXTERNAL_URL.match(text).nil?
    end

    # Paint value syntax: colours, `none`, and fragment references for gradients.
    def self.paint?(value : String) : Bool
      trimmed = value.strip
      return false if trimmed.empty?
      return true if FRAGMENT_PAINT.match(trimmed)
      return false if UNSAFE_TEXT.match(trimmed)
      !HEX_COLOUR.match(trimmed).nil? || !FUNCTION_COLOUR.match(trimmed).nil? || NAMED_COLOURS.includes?(trimmed.downcase)
    end

    def self.number?(value : String) : Bool
      !NUMBER.match(value.strip).nil?
    end

    def self.length?(value : String) : Bool
      !LENGTH.match(value.strip).nil?
    end

    def self.opacity?(value : String) : Bool
      trimmed = value.strip
      return trimmed.rchop('%').to_f <= 100 if PERCENTAGE.match(trimmed)
      return false unless NUMBER.match(trimmed)
      number = trimmed.to_f
      number >= 0 && number <= 1
    end

    def self.dash_array?(value : String) : Bool
      trimmed = value.strip
      return true if trimmed == "none"
      parts = trimmed.split(/[\s,]+/).reject(&.empty?)
      !parts.empty? && parts.all? { |part| LENGTH.match(part) }
    end

    def self.class_list?(value : String) : Bool
      value.strip.split(/\s+/).reject(&.empty?).all? { |token| CLASS_TOKEN.match(token) }
    end

    # Nil when the value fits the attribute (or style property), else the reason.
    # `data-*` values may be any text without markup.
    def self.attribute_value_issue(name : String, value : String) : String?
      case name
      when "fill", "stroke"
        paint?(value) ? nil : "#{value.inspect} is not a colour"
      when "stroke-width", "rx", "ry", "font-size"
        length?(value) ? nil : "#{value.inspect} is not a length"
      when "opacity", "fill-opacity", "stroke-opacity"
        opacity?(value) ? nil : "#{value.inspect} is not an opacity between 0 and 1"
      when "stroke-dasharray"
        dash_array?(value) ? nil : "#{value.inspect} is not a dash array"
      when "class"
        class_list?(value) ? nil : "#{value.inspect} is not a class list"
      when "visibility"
        Schema::VISIBILITY_VALUES.includes?(value.strip) ? nil : "#{value.inspect} is not a visibility keyword"
      when "font-family"
        !value.strip.empty? && UNSAFE_TEXT.match(value).nil? ? nil : "#{value.inspect} is not a font family"
      when "font-weight"
        FONT_WEIGHT.match(value.strip) ? nil : "#{value.inspect} is not a font weight"
      when "text-anchor"
        %w(start middle end).includes?(value.strip) ? nil : "#{value.inspect} is not a text anchor"
      else
        if name.starts_with?("data-") && value =~ /[<>]/
          "#{name} may not contain markup"
        end
      end
    end

    # Geometry attribute values on inserted shapes.
    def self.geometry_value_issue(name : String, value : String) : String?
      case name
      when "points"
        numbers = value.strip.split(/[\s,]+/).reject(&.empty?)
        if numbers.size >= 4 && numbers.size.even? && numbers.all? { |number| NUMBER.match(number) }
          nil
        else
          "#{value.inspect} is not a points list"
        end
      when "d"
        path_data_issue(value)
      else
        number?(value) ? nil : "#{name}=#{value.inspect} is not a number"
      end
    end

    # Grammar check of path data: known commands, numeric arguments in whole
    # groups, nothing before the first command, no stray characters.
    def self.path_data_issue(data : String) : String?
      return "empty path data" if data.strip.empty?

      stray = data.gsub(PATH_TOKEN, "").gsub(/[\s,]/, "")
      return "unexpected characters #{stray[0, 12].inspect}" unless stray.empty?

      command : Char? = nil
      pending = 0
      first = true
      data.scan(PATH_TOKEN) do |match|
        token = match[0]
        if token.size == 1 && token[0].ascii_letter?
          return "command #{command} has a partial argument group" if pending > 0
          return "path must start with M" if first && token.upcase != "M"
          first = false
          command = token[0]
          next
        end
        return "number before the first command" if command.nil?
        arity = PATH_ARITY[command.not_nil!.upcase]
        return "Z takes no arguments" if arity == 0
        pending += 1
        pending = 0 if pending == arity
      end
      return "command #{command} has a partial argument group" if pending > 0
      nil
    end
  end
end
