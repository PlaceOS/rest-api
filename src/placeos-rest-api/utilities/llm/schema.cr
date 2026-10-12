require "json"

module PlaceOS::Api::Llm
  # The map edit operation vocabulary, defined once and rendered per vendor.
  #
  # The TypeScript types and JSON schema in user-interfaces `libs/map-editor`
  # are the other copy of this vocabulary; the two have to agree field for
  # field, which `ops-schema.json` in both test suites pins.
  module Schema
    VERSION = 1

    OPS = %w(set_attr set_style_rule set_text transform delete duplicate insert_shape
      set_id reorder group ungroup replace_element replace_path no_change ask)

    SHAPES = %w(rect circle ellipse line polygon polyline path text g)

    POSITIONS = %w(first last)

    # attributes set_attr may touch, plus data-*; style rules take the same list
    ATTRIBUTES = %w(fill stroke stroke-width stroke-dasharray fill-opacity stroke-opacity
      opacity class visibility rx ry font-size font-family font-weight text-anchor)

    # attributes insert_shape may set on top of ATTRIBUTES
    GEOMETRY_ATTRIBUTES = %w(x y width height cx cy r x1 y1 x2 y2 points d transform)

    VISIBILITY_VALUES = %w(visible hidden collapse)

    ID_PATTERN = /\A[A-Za-z][A-Za-z0-9_.-]*\z/

    # the prefix for ids the model makes up when none is asked for
    NEW_ID_PREFIX = "ai-"

    # the fields each op reads; everything else on the op is ignored
    FIELDS_BY_OP = {
      "set_attr"        => %w(target name value),
      "set_style_rule"  => %w(selector declarations),
      "set_text"        => %w(target text),
      "transform"       => %w(target targets translate scale rotate origin),
      "delete"          => %w(target targets),
      "duplicate"       => %w(target new_id translate count id_pattern),
      "insert_shape"    => %w(parent after kind attrs new_id text),
      "set_id"          => %w(target new_id),
      "reorder"         => %w(target before after position),
      "group"           => %w(targets new_id),
      "ungroup"         => %w(target),
      "replace_element" => %w(target markup),
      "replace_path"    => %w(target d),
      "no_change"       => %w(reason),
      "ask"             => %w(question),
    }

    # One property of a strict object. Nullable unless `required`.
    class Field
      getter name : String
      getter type : String
      getter description : String
      getter? required : Bool
      getter values : Array(String)?
      getter properties : Array(Field)?
      getter items : Field?
      getter min_items : Int32?
      getter max_items : Int32?

      def initialize(@name, @type, @description, @required = false, @values = nil,
                     @properties = nil, @items = nil, @min_items = nil, @max_items = nil)
      end
    end

    TARGET_PROPERTIES = [
      Field.new("a", "string", "anchor from the index, e.g. e417"),
      Field.new("id", "string", "element id from the index"),
      Field.new("h", "string", "content hash of the element, from the index"),
    ]

    NUMBER_PAIR = Field.new("n", "number", "", required: true)

    ATTR_PROPERTIES = [
      Field.new("name", "string", "attribute name", required: true),
      Field.new("value", "string", "attribute value", required: true),
    ]

    OP_FIELDS = [
      Field.new("op", "string", "the operation", required: true, values: OPS),
      Field.new("why", "string", "one sentence for the person reviewing the change", required: true),
      Field.new("target", "object", "the element the operation applies to", properties: TARGET_PROPERTIES),
      Field.new("targets", "array", "several elements, for transform, delete and group",
        items: Field.new("t", "object", "", required: true, properties: TARGET_PROPERTIES)),
      Field.new("name", "string", "set_attr: attribute name from the allow-list, or data-*"),
      Field.new("value", "string", "set_attr: the new value, null to remove the attribute"),
      Field.new("selector", "string", "set_style_rule: CSS selector of the rule to add or change"),
      Field.new("declarations", "string", "set_style_rule: declarations, e.g. fill: #eee; stroke: #333"),
      Field.new("text", "string", "set_text and insert_shape text: the text content"),
      Field.new("translate", "array", "transform and duplicate: [dx, dy] in user units",
        items: NUMBER_PAIR, min_items: 2, max_items: 2),
      Field.new("scale", "array", "transform: [sx, sy]", items: NUMBER_PAIR, min_items: 2, max_items: 2),
      Field.new("rotate", "number", "transform: degrees clockwise"),
      Field.new("origin", "array", "transform: [x, y] the point scale and rotate act about",
        items: NUMBER_PAIR, min_items: 2, max_items: 2),
      Field.new("new_id", "string", "duplicate, insert_shape, group: id for the new element; set_id: the new id, null to remove the id"),
      Field.new("count", "integer", "duplicate: number of copies, each offset by translate again"),
      Field.new("id_pattern", "string", "duplicate: id pattern for the copies, e.g. table-01.{n:03}"),
      Field.new("parent", "object", "insert_shape: the group to insert into, the root when null", properties: TARGET_PROPERTIES),
      Field.new("after", "object", "insert_shape: insert after this sibling; reorder: move after this sibling", properties: TARGET_PROPERTIES),
      Field.new("before", "object", "reorder: move before this sibling", properties: TARGET_PROPERTIES),
      Field.new("position", "string", "reorder: first or last among the siblings", values: POSITIONS),
      Field.new("kind", "string", "insert_shape: the element to create", values: SHAPES),
      Field.new("attrs", "array", "insert_shape: attributes of the new element",
        items: Field.new("attr", "object", "", required: true, properties: ATTR_PROPERTIES)),
      Field.new("markup", "string", "replace_element: the replacement element's SVG markup"),
      Field.new("d", "string", "replace_path: the new path data"),
      Field.new("reason", "string", "no_change: why nothing needs to change"),
      Field.new("question", "string", "ask: the question for the person"),
    ]

    ENVELOPE_FIELDS = [
      Field.new("summary", "string", "one sentence for the person", required: true),
      Field.new("ops", "array", "the operations, in order", required: true,
        items: Field.new("op", "object", "", required: true, properties: OP_FIELDS)),
      Field.new("questions", "array", "questions for the person, usually empty", required: true,
        items: Field.new("q", "string", "", required: true)),
    ]

    OPENAI_NAME = "map_edit"

    # The envelope in the OpenAI strict dialect: every object closed with
    # additionalProperties false and every property listed in required;
    # optional fields are nullable through ["T", "null"].
    @@openai : JSON::Any?

    def self.openai : JSON::Any
      @@openai ||= JSON::Any.new(render_object(ENVELOPE_FIELDS))
    end

    private def self.render_object(fields : Array(Field)) : Hash(String, JSON::Any)
      properties = {} of String => JSON::Any
      fields.each { |field| properties[field.name] = JSON::Any.new(render(field)) }
      {
        "type"                 => JSON::Any.new("object"),
        "properties"           => JSON::Any.new(properties),
        "required"             => JSON::Any.new(fields.map { |field| JSON::Any.new(field.name) }),
        "additionalProperties" => JSON::Any.new(false),
      }
    end

    private def self.render(field : Field) : Hash(String, JSON::Any)
      rendered = if (properties = field.properties)
                   render_object(properties)
                 else
                   {"type" => JSON::Any.new(field.type)}
                 end

      unless field.required?
        rendered["type"] = JSON::Any.new([JSON::Any.new(field.type), JSON::Any.new("null")])
      end
      rendered["description"] = JSON::Any.new(field.description) unless field.description.empty?

      if (values = field.values)
        listed = values.map { |value| JSON::Any.new(value) }
        listed << JSON::Any.new(nil) unless field.required?
        rendered["enum"] = JSON::Any.new(listed)
      end
      if (items = field.items)
        rendered["items"] = JSON::Any.new(render(items))
      end
      if (min = field.min_items)
        rendered["minItems"] = JSON::Any.new(min.to_i64)
      end
      if (max = field.max_items)
        rendered["maxItems"] = JSON::Any.new(max.to_i64)
      end
      rendered
    end

    # One line per op naming the fields it reads, for the system prompt.
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
      ATTRIBUTES.includes?(name) || !(/\Adata-[A-Za-z0-9_.-]+\z/ =~ name).nil?
    end
  end
end
