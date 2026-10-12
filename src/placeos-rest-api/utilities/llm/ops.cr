require "json"
require "xml"

module PlaceOS::Api::Llm
  # Reads the model's answer and checks each operation against the context the
  # editor posted. Failing ops are kept with `server_issue` set so the client can
  # show them unchecked with the reason; the client's own validator, which has
  # the live document, remains the authority.
  module Ops
    record Envelope, summary : String, ops : Array(Hash(String, JSON::Any)), questions : Array(String)

    FENCE = /\A\s*```[a-zA-Z]*\s*(.*?)\s*```\s*\z/m

    MAX_MARKUP_BYTES = 16_384
    MAX_DUPLICATES   =     40

    DENIED_ELEMENTS = %w(script foreignObject iframe embed object animate set animateMotion animateTransform use image a)

    # The whole answer as JSON, with a markdown fence stripped when the model
    # wrapped it in one.
    def self.parse(text : String) : Envelope
      body = text.strip
      if (match = FENCE.match(body))
        body = match[1]
      end
      raise Error::ImageGen::InvalidResponse.new("the model returned an empty answer") if body.empty?

      parsed = begin
        JSON.parse(body)
      rescue JSON::ParseException
        raise Error::ImageGen::InvalidResponse.new("the model did not answer with JSON")
      end

      hash = parsed.as_h?
      raise Error::ImageGen::InvalidResponse.new("the model's answer is not an object") if hash.nil?

      ops = hash["ops"]?.try(&.as_a?)
      raise Error::ImageGen::InvalidResponse.new("the model's answer has no ops list") if ops.nil?

      listed = ops.map do |op|
        op.as_h? || {"op" => JSON::Any.new(nil), "server_issue" => JSON::Any.new("not an object")}
      end
      questions = hash["questions"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      Envelope.new(summary: hash["summary"]?.try(&.as_s?) || "", ops: listed, questions: questions)
    end

    # Each op with an `id` ("op-1" ...) and, when it fails a check, a
    # `server_issue` naming the reason.
    def self.check(ops : Array(Hash(String, JSON::Any)), context : JSON::Any) : Array(JSON::Any)
      index = Index.new(context)

      ops.map_with_index do |op, position|
        checked = op.dup
        checked["id"] = JSON::Any.new("op-#{position + 1}")
        issue = if position >= MAP_AI_MAX_OPS
                  "over the limit of #{MAP_AI_MAX_OPS} operations in one answer"
                else
                  checked["server_issue"]?.try(&.as_s?) || issue_for(checked, index)
                end
        checked["server_issue"] = JSON::Any.new(issue) if issue
        JSON::Any.new(checked)
      end
    end

    # What the editor posted, keyed for lookups.
    class Index
      getter anchors : Hash(String, Hash(String, JSON::Any))
      getter ids : Hash(String, Hash(String, JSON::Any))
      getter protected_ids : Set(String)

      def initialize(context : JSON::Any)
        @anchors = {} of String => Hash(String, JSON::Any)
        @ids = {} of String => Hash(String, JSON::Any)
        (context["index"]?.try(&.as_a?) || [] of JSON::Any).each do |entry|
          hash = entry.as_h?
          next unless hash
          if (anchor = hash["a"]?.try(&.as_s?))
            @anchors[anchor] = hash
          end
          if (id = hash["id"]?.try(&.as_s?))
            @ids[id] ||= hash
          end
        end
        @protected_ids = (context["protected_ids"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?).to_set
      end

      # The entry a target names, or the reason it does not resolve.
      def resolve(target : JSON::Any?) : Tuple(Hash(String, JSON::Any)?, String?)
        hash = target.try(&.as_h?)
        return {nil, "target is missing"} if hash.nil?

        anchor = hash["a"]?.try(&.as_s?).presence
        id = hash["id"]?.try(&.as_s?).presence
        return {nil, "target names neither an anchor nor an id"} if anchor.nil? && id.nil?

        by_anchor = anchor ? @anchors[anchor]? : nil
        by_id = id ? @ids[id]? : nil
        return {nil, "anchor #{anchor} is not in the index"} if anchor && by_anchor.nil?
        return {nil, "id #{id} is not in the index"} if id && by_id.nil?
        if by_anchor && by_id && !by_anchor.same?(by_id)
          return {nil, "anchor #{anchor} and id #{id} are different elements"}
        end

        entry = (by_anchor || by_id).not_nil!
        if (hash_given = hash["h"]?.try(&.as_s?).presence) && (current = entry["h"]?.try(&.as_s?)) && hash_given != current
          return {nil, "the element changed since the index was built (hash mismatch)"}
        end
        {entry, nil}
      end

      def known_id?(id : String) : Bool
        @ids.has_key?(id)
      end
    end

    private def self.issue_for(op : Hash(String, JSON::Any), index : Index) : String?
      kind = op["op"]?.try(&.as_s?)
      return "unknown operation #{kind.inspect}" unless kind && Schema::OPS.includes?(kind)

      case kind
      when "set_attr"
        with_target(op, index) do
          name = op["name"]?.try(&.as_s?).presence
          return "set_attr needs a name" unless name
          return "attribute #{name} may not be set" unless Schema.allowed_attribute?(name)
          value = op["value"]?.try(&.as_s?)
          if name == "visibility" && value && !Schema::VISIBILITY_VALUES.includes?(value.strip)
            return "visibility must be one of #{Schema::VISIBILITY_VALUES.join(", ")}"
          end
          nil
        end
      when "set_style_rule"
        selector = op["selector"]?.try(&.as_s?).try(&.strip).presence
        declarations = op["declarations"]?.try(&.as_s?).try(&.strip).presence
        return "set_style_rule needs a selector" unless selector
        return "the selector * is not allowed" if selector == "*"
        return "set_style_rule needs declarations" unless declarations
        css_issue(declarations)
      when "set_text"
        with_target(op, index) do |entry|
          tag = entry["tag"]?.try(&.as_s?)
          tag == "text" || tag == "tspan" ? nil : "set_text only applies to text and tspan elements"
        end
      when "transform"
        unless op["translate"]? || op["scale"]? || op["rotate"]?
          return "transform needs translate, scale or rotate"
        end
        return "translate must be [dx, dy]" unless pair?(op["translate"]?)
        return "scale must be [sx, sy]" unless pair?(op["scale"]?)
        return "origin must be [x, y]" unless pair?(op["origin"]?)
        with_targets(op, index) { nil }
      when "delete"
        with_targets(op, index) { nil }
      when "duplicate"
        with_target(op, index) do
          return "translate must be [dx, dy]" unless pair?(op["translate"]?)
          count = op["count"]?.try(&.as_i?)
          return "count must be between 1 and #{MAX_DUPLICATES}" if count && (count < 1 || count > MAX_DUPLICATES)
          new_id_issue(op["new_id"]?, index)
        end
      when "insert_shape"
        shape = op["kind"]?.try(&.as_s?)
        return "insert_shape needs a kind" unless shape
        return "#{shape} is not a shape that can be inserted" unless Schema::SHAPES.includes?(shape)
        if op["parent"]? && !op["parent"].raw.nil?
          _, issue = index.resolve(op["parent"])
          return "parent: #{issue}" if issue
        end
        if op["after"]? && !op["after"].raw.nil?
          _, issue = index.resolve(op["after"])
          return "after: #{issue}" if issue
        end
        (op["attrs"]?.try(&.as_a?) || [] of JSON::Any).each do |attr|
          name = attr["name"]?.try(&.as_s?)
          return "an attribute has no name" unless name
          unless Schema.allowed_attribute?(name) || Schema::GEOMETRY_ATTRIBUTES.includes?(name)
            return "attribute #{name} may not be set on a new element"
          end
        end
        new_id_issue(op["new_id"]?, index)
      when "set_id"
        with_target(op, index) do
          new_id = op["new_id"]?
          new_id.nil? || new_id.raw.nil? ? nil : new_id_issue(new_id, index)
        end
      when "reorder"
        with_target(op, index) do
          where = [op["before"]?, op["after"]?, op["position"]?].count { |value| value && !value.raw.nil? }
          return "reorder needs exactly one of before, after or position" unless where == 1
          if (position = op["position"]?.try(&.as_s?)) && !Schema::POSITIONS.includes?(position)
            return "position must be first or last"
          end
          {op["before"]?, op["after"]?}.each do |sibling|
            next if sibling.nil? || sibling.raw.nil?
            _, issue = index.resolve(sibling)
            return issue if issue
          end
          nil
        end
      when "group"
        targets = op["targets"]?.try(&.as_a?)
        return "group needs targets" if targets.nil? || targets.empty?
        targets.each do |target|
          _, issue = index.resolve(target)
          return issue if issue
        end
        new_id_issue(op["new_id"]?, index)
      when "ungroup"
        with_target(op, index) do |entry|
          entry["tag"]?.try(&.as_s?) == "g" ? nil : "ungroup only applies to a group"
        end
      when "replace_element"
        with_target(op, index) do
          markup = op["markup"]?.try(&.as_s?).try(&.strip).presence
          return "replace_element needs markup" unless markup
          return "the markup is larger than #{MAX_MARKUP_BYTES // 1024}KB" if markup.bytesize > MAX_MARKUP_BYTES
          markup_issue(markup)
        end
      when "replace_path"
        with_target(op, index) do |entry|
          return "replace_path only applies to a path" unless entry["tag"]?.try(&.as_s?) == "path"
          data = op["d"]?.try(&.as_s?).try(&.strip).presence
          return "replace_path needs d" unless data
          /\A[MmZzLlHhVvCcSsQqTtAa0-9\s,.\-+eE]+\z/.match(data) ? nil : "d is not path data"
        end
      when "no_change"
        op["reason"]?.try(&.as_s?).presence ? nil : "no_change needs a reason"
      when "ask"
        op["question"]?.try(&.as_s?).presence ? nil : "ask needs a question"
      end
    end

    private def self.with_target(op : Hash(String, JSON::Any), index : Index, & : Hash(String, JSON::Any) -> String?) : String?
      entry, issue = index.resolve(op["target"]?)
      return issue if issue
      yield entry.not_nil!
    end

    private def self.with_targets(op : Hash(String, JSON::Any), index : Index, & : Array(Hash(String, JSON::Any)) -> String?) : String?
      listed = [] of JSON::Any
      if (target = op["target"]?) && !target.raw.nil?
        listed << target
      end
      if (targets = op["targets"]?.try(&.as_a?))
        listed.concat(targets)
      end
      return "no target given" if listed.empty?

      entries = listed.map do |item|
        entry, issue = index.resolve(item)
        return issue if issue
        entry.not_nil!
      end
      yield entries
    end

    private def self.pair?(value : JSON::Any?) : Bool
      return true if value.nil? || value.raw.nil?
      list = value.as_a?
      !list.nil? && list.size == 2 && list.all? { |item| item.as_f? || item.as_i? }
    end

    private def self.new_id_issue(value : JSON::Any?, index : Index) : String?
      return if value.nil? || value.raw.nil?
      id = value.as_s?
      return "new_id must be a string" if id.nil?
      return "#{id.inspect} is not a valid id (letter first, then letters, digits, _ . -)" unless Schema.valid_id?(id)
      return "#{id} is already an id in the map" if index.known_id?(id)
      return "#{id} is a protected id" if index.protected_ids.includes?(id)
      nil
    end

    private def self.css_issue(declarations : String) : String?
      lowered = declarations.downcase
      return "declarations may not import or reference URLs" if lowered.includes?("@import") || lowered.includes?("url(") || lowered.includes?("expression(") || lowered.includes?("behavior:")

      declarations.split(';').each do |declaration|
        next if declaration.strip.empty?
        name, _, value = declaration.partition(':')
        name = name.strip
        return "declaration #{declaration.strip.inspect} has no value" if value.strip.empty?
        return "property #{name} may not be set" unless Schema.allowed_attribute?(name)
      end
      nil
    end

    # A libxml2 walk of replacement markup: one root element, nothing from the
    # deny list, no event handlers, no external references.
    private def self.markup_issue(markup : String) : String?
      document = begin
        XML.parse("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">#{markup}</svg>", XML::ParserOptions::NONET)
      rescue
        return "the markup does not parse"
      end
      return "the markup does not parse: #{document.errors.try(&.first?).try(&.message)}" unless document.errors.nil? || document.errors.not_nil!.empty?

      wrapper = document.root
      return "the markup does not parse" if wrapper.nil?
      roots = wrapper.children.select(&.element?)
      return "the markup must be exactly one element" unless roots.size == 1

      elements = [] of XML::Node
      collect_elements(roots.first, elements)
      elements.each do |node|
        name = node.name
        return "<#{name}> is not allowed" if DENIED_ELEMENTS.includes?(name)
        if name == "style" && (text = node.content) && css_issue(text.gsub(/[^{}]*\{/, "").gsub('}', ';'))
          return "the style content is not allowed"
        end
        node.attributes.each do |attribute|
          attr_name = attribute.name
          value = attribute.content
          return "event handler attributes are not allowed" if attr_name.downcase.starts_with?("on")
          return "href must point inside the document" if attr_name == "href" && !value.starts_with?('#')
          return "the style attribute content is not allowed" if attr_name == "style" && css_issue(value)
        end
      end
      nil
    end

    private def self.collect_elements(node : XML::Node, found : Array(XML::Node)) : Nil
      found << node if node.element?
      node.children.each { |child| collect_elements(child, found) }
    end
  end
end
