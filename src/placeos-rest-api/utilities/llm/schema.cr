require "json"

module PlaceOS::Api::Llm
  # The map edit operation vocabulary, `ops-schema.json` beside this file: the
  # same file as `libs/map-editor/src/lib/ops-schema.json` in user-interfaces,
  # which the editor validates proposals against.
  module Schema
    VERSION = 1

    SOURCE   = {{ read_file("#{__DIR__}/ops-schema.json") }}
    DOCUMENT = JSON.parse(SOURCE)

    # the op variants of `ops.items.anyOf`, keyed by op name, in schema order
    VARIANTS = DOCUMENT["properties"]["ops"]["items"]["anyOf"].as_a.to_h do |variant|
      {variant["properties"]["op"]["enum"][0].as_s, variant}
    end

    OPS = VARIANTS.keys

    # the fields each op carries besides `op` and `why`
    FIELDS_BY_OP = VARIANTS.to_h do |op, variant|
      {op, variant["properties"].as_h.keys.reject { |key| key == "op" || key == "why" }}
    end

    SHAPES    = VARIANTS["insert_shape"]["properties"]["kind"]["enum"].as_a.map(&.as_s)
    POSITIONS = VARIANTS["reorder"]["properties"]["position"]["enum"].as_a.compact_map(&.as_s?)

    # attributes set_attr may touch, plus data-*; style rules take the same list
    ATTRIBUTES = %w(fill stroke stroke-width stroke-dasharray fill-opacity stroke-opacity
      opacity class visibility rx ry font-size font-family font-weight text-anchor)

    DATA_ATTRIBUTE = /\Adata-[a-z][a-z0-9_-]*\z/i

    # `data-map-editor-*` is the editor's own session state
    EDITOR_ATTRIBUTE_PREFIX = "data-map-editor-"

    # geometry attributes insert_shape may set per kind, on top of ATTRIBUTES
    SHAPE_GEOMETRY_ATTRIBUTES = {
      "rect"     => %w(x y width height rx ry),
      "circle"   => %w(cx cy r),
      "ellipse"  => %w(cx cy rx ry),
      "line"     => %w(x1 y1 x2 y2),
      "polygon"  => %w(points),
      "polyline" => %w(points),
      "path"     => %w(d),
      "text"     => %w(x y dx dy),
      "g"        => %w(),
    }

    VISIBILITY_VALUES = %w(visible hidden collapse)

    ID_PATTERN = /\A[A-Za-z][A-Za-z0-9_.-]*\z/

    # the prefix for ids the model makes up when none is asked for
    NEW_ID_PREFIX = "ai-"

    OPENAI_NAME = "map_edit"

    # The schema as sent to OpenAI: `response_format.json_schema.schema`.
    def self.openai : JSON::Any
      DOCUMENT
    end

    private NULLABLE_STRING_TYPE = JSON.parse(%(["string","null"]))

    # Anthropic allows at most 16 union parameters in a structured output schema.
    def self.anthropic(node : JSON::Any = DOCUMENT) : JSON::Any
      definitions = {} of String => JSON::Any
      converted = anthropic_node(node, definitions)
      unless definitions.empty?
        existing = converted.as_h["$defs"]?.try(&.as_h?) || {} of String => JSON::Any
        converted.as_h["$defs"] = JSON::Any.new(existing.merge(definitions))
      end
      # Empty target strings are treated as absent by both operation validators.
      if target = converted["$defs"]?.try(&.["target"]?)
        target["properties"].as_h.each_key do |key|
          target["properties"].as_h[key] = JSON.parse(%({"type":"string","description":"Use an empty string when this target field is not needed."}))
        end
      end
      converted
    end

    private def self.anthropic_node(node : JSON::Any, definitions : Hash(String, JSON::Any)) : JSON::Any
      if hash = node.as_h?
        converted = hash.transform_values { |value| anthropic_node(value, definitions) }
        if hash["type"]? == NULLABLE_STRING_TYPE && (values = hash["enum"]?.try(&.as_a?))
          branches = [] of JSON::Any
          strings = values.select { |value| value.as_s? }
          unless strings.empty?
            branches << JSON::Any.new({"type" => JSON::Any.new("string"), "enum" => JSON::Any.new(strings)})
          end
          if values.any?(&.raw.nil?)
            branches << JSON::Any.new({"type" => JSON::Any.new("null")})
          end
          converted.delete("type")
          converted.delete("enum")
          converted["anyOf"] = JSON::Any.new(branches)
        end
        nullable = converted["type"]?.try(&.as_a?).try(&.any? { |type| type.as_s? == "null" }) ||
                   converted["anyOf"]?.try(&.as_a?).try(&.any? { |option| option.as_h?.try(&.["type"]?).try(&.as_s?) == "null" })
        if nullable
          description = converted.delete("description")
          definition = JSON::Any.new(converted)
          name = definitions.find { |_, value| value == definition }.try(&.[0]) || "anthropic_nullable_#{definitions.size}"
          definitions[name] = definition
          reference = {"$ref" => JSON::Any.new("#/$defs/#{name}")}
          reference["description"] = description if description
          JSON::Any.new(reference)
        else
          JSON::Any.new(converted)
        end
      elsif list = node.as_a?
        JSON::Any.new(list.map { |value| anthropic_node(value, definitions) })
      else
        node
      end
    end

    # One line per op naming the fields it carries, for the system prompt.
    def self.reference : String
      String.build do |text|
        FIELDS_BY_OP.each do |op, fields|
          text << op << ": " << fields.join(", ") << '\n'
        end
      end
    end

    def self.valid_id?(id : String) : Bool
      !ID_PATTERN.match(id).nil?
    end

    def self.allowed_attribute?(name : String) : Bool
      return true if ATTRIBUTES.includes?(name)
      !DATA_ATTRIBUTE.match(name).nil? && !name.downcase.starts_with?(EDITOR_ATTRIBUTE_PREFIX)
    end
  end
end
