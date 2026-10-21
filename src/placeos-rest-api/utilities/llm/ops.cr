require "json"
require "xml"

module PlaceOS::Api::Llm
  # Reads the model's answer and checks each operation against the context the
  # editor posted. Ops are kept as the model returned them; an op that fails a
  # check is named in `issues` by its id so the editor can show it unchecked
  # with the reason. The editor's own validator, which has the live document,
  # remains the authority.
  module Ops
    record Envelope, summary : String, ops : Array(JSON::Any), questions : Array(String)

    # `issues` is keyed by op id: `op-N`, N the op's 1-based position in `ops`
    record Checked, ops : Array(JSON::Any), issues : Hash(String, String)

    FENCE = /\A\s*```[a-zA-Z]*\s*(.*?)\s*```\s*\z/m

    MAX_MARKUP_BYTES = 16_384
    MAX_DUPLICATES   =     40

    SVG_NS = "http://www.w3.org/2000/svg"

    # `sanitise.ts` DENIED_TAGS, plus style (the sheet changes only through
    # set_style_rule) and use (DOMPurify's SVG profile drops it); compared lower-cased
    DENIED_ELEMENTS = %w(script foreignobject handler iframe embed object animate animatecolor
      animatemotion animatetransform set discard mpath style use)

    REFERENCE_ATTRIBUTES = %w(href xlink:href src)

    DATA_IMAGE = /\Adata:image\/(?:png|jpe?g|gif|webp|svg\+xml);/i

    def self.id_for(position : Int32) : String
      "op-#{position + 1}"
    end

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

      ops = list(hash["ops"]?)
      if ops.nil?
        shape = hash.map { |key, value| "#{key}: #{kind_of(value)}" }.join(", ")
        Log.warn { "map AI answer has no ops list; fields: #{shape}" }
        raise Error::ImageGen::InvalidResponse.new("the model's answer has no ops list")
      end

      questions = list(hash["questions"]?).try(&.compact_map(&.as_s?)) || [] of String
      Envelope.new(summary: hash["summary"]?.try(&.as_s?) || "", ops: ops, questions: questions)
    end

    # An array, or a string holding a JSON array: Claude sometimes sends a
    # nested tool input parameter JSON-encoded as a string.
    private def self.list(value : JSON::Any?) : Array(JSON::Any)?
      return nil if value.nil?
      if (array = value.as_a?)
        return array
      end
      text = value.as_s?
      return nil if text.nil?
      JSON.parse(text).as_a?
    rescue JSON::ParseException
      nil
    end

    private def self.kind_of(value : JSON::Any) : String
      case raw = value.raw
      when Array  then "array"
      when Hash   then "object"
      when String then "string (#{raw.bytesize} bytes)"
      when Nil    then "null"
      else             raw.class.name.downcase
      end
    end

    # The ops untouched, with the reason for each one that fails a check.
    def self.check(ops : Array(JSON::Any), context : JSON::Any) : Checked
      index = Index.new(context)
      claimed = Set(String).new
      issues = {} of String => String

      ops.each_with_index do |op, position|
        issue = if position >= MAP_AI_MAX_OPS
                  "over the limit of #{MAP_AI_MAX_OPS} operations in one answer"
                elsif (hash = op.as_h?)
                  issue_for(hash, index, claimed)
                else
                  "not an object"
                end
        if issue
          issues[id_for(position)] = issue
        elsif (hash = op.as_h?)
          index.register_rename(hash, claimed)
          index.register_created(hash)
          index.register_structure(hash)
        end
      end

      Checked.new(ops: ops, issues: issues)
    end

    # What the editor posted, keyed for lookups.
    class Index
      getter anchors : Hash(String, Hash(String, JSON::Any))
      getter ids : Hash(String, Hash(String, JSON::Any))
      getter protected_ids : Set(String)
      # The map's viewBox as x, y, width, height; nil when the context has none.
      getter view_box : Array(Float64)?
      # anchors an earlier op in the batch deletes; an insert placed after one goes where it was
      getter deleted = Set(String).new
      # set once an earlier op in the batch can move elements to another parent
      getter? restructured = false

      def initialize(context : JSON::Any)
        @anchors = {} of String => Hash(String, JSON::Any)
        @ids = {} of String => Hash(String, JSON::Any)
        (context["index"]?.try(&.as_a?) || [] of JSON::Any).each do |entry|
          hash = entry.as_h?.try(&.dup)
          next unless hash
          if (anchor = hash["a"]?.try(&.as_s?))
            @anchors[anchor] = hash
          end
          if (id = hash["id"]?.try(&.as_s?))
            @ids[id] ||= hash
          end
        end
        @protected_ids = (context["protected_ids"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?).to_set
        numbers = (context["viewBox"]?.try(&.as_a?) || [] of JSON::Any).compact_map { |value| value.as_f? || value.as_i64?.try(&.to_f) }
        @view_box = numbers if numbers.size == 4 && numbers[2] > 0 && numbers[3] > 0
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

      # Id ownership follows accepted renames in proposal order.
      def register_rename(op : Hash(String, JSON::Any), claimed : Set(String)) : Nil
        return unless op["op"]?.try(&.as_s?) == "set_id"
        entry, _ = resolve(op["target"]?)
        return unless entry
        if (old_id = entry["id"]?.try(&.as_s?))
          @ids.delete(old_id)
          claimed.delete(old_id)
        end
        if (new_id = op["new_id"]?.try(&.as_s?).presence)
          entry["id"] = JSON::Any.new(new_id)
          @ids[new_id] = entry
        else
          entry.delete("id")
        end
      end

      # Later operations may reference explicit ids created earlier in this batch.
      def register_created(op : Hash(String, JSON::Any)) : Nil
        id = op["new_id"]?.try(&.as_s?).presence
        return unless id
        tag = case op["op"]?.try(&.as_s?)
              when "duplicate"
                return if op["id_pattern"]?.try(&.as_s?).presence
                entry, _ = resolve(op["target"]?)
                entry.try(&.["tag"]?).try(&.as_s?)
              when "insert_shape"
                op["kind"]?.try(&.as_s?)
              when "group"
                "g"
              end
        return unless tag
        count = op["op"]?.try(&.as_s?) == "duplicate" ? (op["count"]?.try(&.as_i?) || 1) : 1
        count.times do |offset|
          created_id = offset == 0 ? id : "#{id}-#{offset + 1}"
          @ids[created_id] ||= {"id" => JSON::Any.new(created_id), "tag" => JSON::Any.new(tag)}
        end
      end

      def known_id?(id : String) : Bool
        @ids.has_key?(id)
      end

      # Records what an accepted op does to the tree that later insert_shape
      # checks rely on.
      def register_structure(op : Hash(String, JSON::Any)) : Nil
        case op["op"]?.try(&.as_s?)
        when "delete"
          targets = op["targets"]?.try(&.as_a?) || [] of JSON::Any
          ([op["target"]?] + targets).each do |target|
            entry, _ = resolve(target)
            if (anchor = entry.try(&.["a"]?).try(&.as_s?))
              @deleted << anchor
            end
          end
        when "reorder", "group", "ungroup", "replace_element"
          @restructured = true
        end
      end

      # The editor's rule for insert_shape: `after` is a direct child of
      # `parent`, the root when none is named. Nil when it holds or cannot be
      # judged from the index: `after` or `parent` made in this batch, `after`
      # deleted earlier in it, or the tree restructured by an earlier op.
      def sibling_issue(parent : Hash(String, JSON::Any)?, after : Hash(String, JSON::Any)) : String?
        return nil if restructured?
        return nil unless after.has_key?("p")
        anchor = after["a"]?.try(&.as_s?)
        return nil if anchor && @deleted.includes?(anchor)

        expected = nil
        if parent && parent["tag"]?.try(&.as_s?) != "svg"
          expected = parent["a"]?.try(&.as_s?)
          return nil unless expected
        end
        after["p"]?.try(&.as_s?) == expected ? nil : "after must be a child of the parent"
      end
    end

    # The editor's `canvasExpansionIssue`: the new bounds keep the whole old
    # viewBox and grow neither dimension nor the area beyond four times.
    def self.canvas_expansion_issue(before : Array(Float64)?, after : Array(Float64)) : String?
      return nil unless before
      bx, by, bw, bh = before
      ax, ay, aw, ah = after
      if ax > bx || ay > by || ax + aw < bx + bw || ay + ah < by + bh
        return "the canvas may expand but cannot crop the existing map"
      end
      if aw > bw * 4 || ah > bh * 4 || aw * ah > bw * bh * 4
        return "the canvas expansion exceeds four times the existing size"
      end
      nil
    end

    private def self.issue_for(op : Hash(String, JSON::Any), index : Index, claimed : Set(String)) : String?
      kind = op["op"]?.try(&.as_s?)
      return "unknown operation #{kind.inspect}" unless kind && Schema::OPS.includes?(kind)

      case kind
      when "set_attr"
        with_target(op, index) do |entry|
          name = op["name"]?.try(&.as_s?).try(&.strip).presence
          return "set_attr needs a name" unless name
          if name == "viewBox"
            return "canvas bounds can only be changed on the SVG root" unless entry["kind"]?.try(&.as_s?) == "root"
            tokens = op["value"]?.try(&.as_s?).try(&.strip.split(/[\s,]+/)) || [] of String
            numbers = tokens.compact_map(&.to_f64?)
            return "canvas bounds need four finite numbers with positive dimensions" unless tokens.size == 4 && numbers.size == 4 && numbers.all?(&.finite?) && numbers[2] > 0 && numbers[3] > 0
            return Ops.canvas_expansion_issue(index.view_box, numbers)
          end
          return "attribute #{name} may not be set" unless Schema.allowed_attribute?(name)
          if (value = op["value"]?.try(&.as_s?))
            Values.attribute_value_issue(name, value)
          end
        end
      when "set_style_rule"
        selector = op["selector"]?.try(&.as_s?).try(&.strip).presence
        return "set_style_rule needs a selector" unless selector
        if selector == "*" || selector.includes?(',') || selector =~ /[{};@\/\\]/ || Values.unsafe_css?(selector)
          return "the selector #{selector.inspect} is not allowed"
        end
        declarations_issue(op["declarations"]?)
      when "set_text"
        with_target(op, index) do |entry|
          tag = entry["tag"]?.try(&.as_s?)
          tag == "text" || tag == "tspan" ? nil : "set_text only applies to text and tspan elements"
        end
      when "transform"
        unless present?(op["translate"]?) || present?(op["scale"]?) || present?(op["rotate"]?)
          return "transform needs translate, scale or rotate"
        end
        return "translate must be [dx, dy]" unless pair?(op["translate"]?)
        return "scale must be [sx, sy]" unless pair?(op["scale"]?)
        return "rotate must be a number" unless number?(op["rotate"]?)
        return "origin must be [x, y]" unless pair?(op["origin"]?)
        with_targets(op, index) { nil }
      when "delete"
        with_targets(op, index) { nil }
      when "duplicate"
        with_target(op, index) do
          return "duplicate needs translate" unless present?(op["translate"]?)
          return "translate must be [dx, dy]" unless pair?(op["translate"]?)
          if (count = op["count"]?) && !count.raw.nil?
            whole = count.as_i?
            return "count must be a whole number" if whole.nil?
            return "count must be between 1 and #{MAX_DUPLICATES}" if whole < 1 || whole > MAX_DUPLICATES
          end
          if (new_id = op["new_id"]?.try(&.as_s?)) && !op["id_pattern"]?.try(&.as_s?).presence
            pending = claimed.dup
            (op["count"]?.try(&.as_i?) || 1).times do |offset|
              id = offset == 0 ? new_id : "#{new_id}-#{offset + 1}"
              issue = new_id_issue(JSON::Any.new(id), index, pending)
              return issue if issue
            end
            claimed.concat(pending)
            nil
          else
            new_id_issue(op["new_id"]?, index, claimed)
          end
        end
      when "insert_shape"
        shape = op["kind"]?.try(&.as_s?)
        return "insert_shape needs a kind" unless shape
        return "#{shape} is not a shape that can be inserted" unless Schema::SHAPES.includes?(shape)
        parent = nil
        if present?(op["parent"]?)
          parent, issue = index.resolve(op["parent"])
          return "parent: #{issue}" if issue
        end
        if (tag = parent.try(&.["tag"]?).try(&.as_s?)) && !{"g", "svg"}.includes?(tag)
          return "parent must be the root or a <g>, not <#{tag}>"
        end
        if present?(op["after"]?)
          after, issue = index.resolve(op["after"])
          return "after: #{issue}" if issue
          if after && (misplaced = index.sibling_issue(parent, after))
            return misplaced
          end
        end
        geometry = Schema::SHAPE_GEOMETRY_ATTRIBUTES[shape]
        (op["attrs"]?.try(&.as_a?) || [] of JSON::Any).each do |attr|
          pair = attr.as_h?
          name = pair.try(&.["name"]?).try(&.as_s?).try(&.strip).presence
          return "an attribute has no name" unless pair && name
          value = pair["value"]?.try(&.as_s?) || ""
          issue = if geometry.includes?(name)
                    Values.geometry_value_issue(name, value)
                  elsif Schema.allowed_attribute?(name)
                    Values.attribute_value_issue(name, value)
                  else
                    "attribute #{name} is not allowed on a #{shape}"
                  end
          return issue if issue
        end
        new_id_issue(op["new_id"]?, index, claimed)
      when "set_id"
        with_target(op, index) do
          present?(op["new_id"]?) ? new_id_issue(op["new_id"], index, claimed) : nil
        end
      when "reorder"
        with_target(op, index) do
          where = [op["before"]?, op["after"]?, op["position"]?].count { |value| present?(value) }
          return "reorder needs exactly one of before, after or position" unless where == 1
          if (position = op["position"]?.try(&.as_s?)) && !Schema::POSITIONS.includes?(position)
            return "position must be #{Schema::POSITIONS.join(" or ")}"
          end
          {op["before"]?, op["after"]?}.each do |sibling|
            next unless present?(sibling)
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
        new_id_issue(op["new_id"]?, index, claimed)
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
          data = op["d"]?.try(&.as_s?)
          return "replace_path needs d" if data.nil? || data.strip.empty?
          Values.path_data_issue(data)
        end
      when "no_change"
        op["reason"]?.try(&.as_s?).presence ? nil : "no_change needs a reason"
      when "ask"
        op["question"]?.try(&.as_s?).presence ? nil : "ask needs a question"
      end
    end

    private def self.declarations_issue(declarations : JSON::Any?) : String?
      listed = declarations.try(&.as_a?)
      return "set_style_rule needs declarations" if listed.nil? || listed.empty?

      listed.each do |declaration|
        pair = declaration.as_h?
        name = pair.try(&.["name"]?).try(&.as_s?).try(&.strip).presence
        return "a declaration has no property name" unless pair && name
        return "property #{name} may not be set" unless Schema.allowed_attribute?(name)
        value = pair["value"]?.try(&.as_s?)
        return "declaration #{name} has no value" if value.nil? || value.strip.empty?
        return "the value of #{name} is not allowed" if Values.unsafe_css?(value)
        if (issue = Values.attribute_value_issue(name, value))
          return issue
        end
      end
      nil
    end

    private def self.with_target(op : Hash(String, JSON::Any), index : Index, & : Hash(String, JSON::Any) -> String?) : String?
      entry, issue = index.resolve(op["target"]?)
      return issue if issue
      yield entry.not_nil!
    end

    private def self.with_targets(op : Hash(String, JSON::Any), index : Index, & : Array(Hash(String, JSON::Any)) -> String?) : String?
      listed = [] of JSON::Any
      if present?(target = op["target"]?)
        listed << target.not_nil!
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

    # a field that is there and not JSON null
    private def self.present?(value : JSON::Any?) : Bool
      !value.nil? && !value.raw.nil?
    end

    private def self.number?(value : JSON::Any?) : Bool
      return true unless present?(value)
      !value.not_nil!.as_f?.nil? || !value.not_nil!.as_i?.nil?
    end

    private def self.pair?(value : JSON::Any?) : Bool
      return true unless present?(value)
      list = value.not_nil!.as_a?
      !list.nil? && list.size == 2 && list.all? { |item| item.as_f? || item.as_i? }
    end

    # An id a new element takes: well formed, not in the map, not bound, and
    # not already taken by an earlier op of this answer.
    private def self.new_id_issue(value : JSON::Any?, index : Index, claimed : Set(String)) : String?
      return unless present?(value)
      id = value.not_nil!.as_s?
      return "new_id must be a string" if id.nil?
      return "#{id.inspect} is not a valid id (letter first, then letters, digits, _ . -)" unless Schema.valid_id?(id)
      return "#{id} is used twice in this answer" if claimed.includes?(id)
      return "#{id} is already an id in the map" if index.known_id?(id)
      return "#{id} is a protected id" if index.protected_ids.includes?(id)
      claimed << id
      nil
    end

    # A libxml2 walk of replacement markup: one root element, everything in
    # the SVG namespace, nothing from the deny list, no event handlers, and no
    # reference outside the document.
    private def self.markup_issue(markup : String) : String?
      document = begin
        XML.parse("<svg xmlns=\"#{SVG_NS}\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">#{markup}</svg>", XML::ParserOptions::NONET)
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
        tag = name.downcase
        return "<#{name}> is not allowed" if DENIED_ELEMENTS.includes?(tag)
        return "<#{name}> is outside the SVG namespace" unless node.namespace.try(&.href) == SVG_NS

        node.attributes.each do |attribute|
          attr_name = if (prefix = attribute.namespace.try(&.prefix).presence)
                        "#{prefix}:#{attribute.name}"
                      else
                        attribute.name
                      end
          lower = attr_name.downcase
          value = attribute.content.strip
          return "attribute #{attr_name} is not allowed" if lower.starts_with?("on")
          if REFERENCE_ATTRIBUTES.includes?(lower) || lower.ends_with?(":href")
            unless value.starts_with?('#') || (tag == "image" && DATA_IMAGE.match(value))
              return "#{attr_name} must reference an id in the document"
            end
          end
          return "style contains an unsafe value" if lower == "style" && Values.unsafe_css?(value)
          return "#{attr_name} may not reference anything outside the document" if Values.external_url?(value)
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
