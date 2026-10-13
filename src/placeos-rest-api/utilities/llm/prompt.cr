require "json"

module PlaceOS::Api::Llm
  # Builds the vendor request for a map edit from the context the editor posted.
  #
  # Parts go in this order: rules and the op reference (system), then the index,
  # the subtrees, the snapshot image, the annotations, earlier turns, and the
  # instruction last.
  module Prompt
    CONTEXT_SCHEMA = "placeos.map-ai-context/1"

    # byte budgets per section; roughly four bytes per token
    MAX_INDEX_BYTES   = 100_000
    MAX_SUBTREE_BYTES =  40_000
    MAX_SUBTREE_EACH  =   8_000
    MAX_STYLE_BYTES   =  16_000
    MAX_MARKUP_BYTES  =  16_000
    MAX_HISTORY_TURNS =       6
    MAX_HISTORY_BYTES =  40_000
    MAX_HISTORY_OPS   =      40

    SYSTEM = <<-TEXT
      You edit SVG floor-plan maps for a workplace platform by returning a list of operations; the application applies them to the SVG document, never you.

      You are given an index of the map's elements (one line each), the markup of a few shortlisted elements, sometimes a snapshot image of the map, and an instruction. Anchors are the first column of the index; the id column is the element's id when it has one. The inside column names the smallest room, desk or zone whose box contains the element. The snapshot shows the map as the person sees it, with the ids of the larger rooms and zones printed at their top-left corner and the person's annotations drawn on it.

      Names and ids: rooms, desks, bays and lockers carry their number in their id (area-1.03-status is room 1.03, table-01.004 is desk 01.004, park-100 is bay 100). A name in the instruction such as "Boardroom 1.03" or "desk 01.004" identifies the element whose id carries that number; the words around the number are the label painted on the map, which the snapshot shows.

      Labels: most labels are outlined into anonymous path elements, one per letter. The LABELS section lists each outlined label the application found: the element it sits in, its glyph anchors in reading order, its box and fill; the index marks those elements kind glyph. The snapshot shows what each label says. To rename an outlined label: delete every glyph anchor of that label, then insert_shape a text element with the new words, after the label's last glyph (the application puts it where the glyphs were), text-anchor middle, x at the centre of the label's box, y at the baseline of the first line (the box's top plus the font size), font-size equal to the box height divided by the number of rows, font-family sans-serif, font-weight bold and the label's fill. Keep the label's rows: separate lines with a newline character in text and the application lays them out one under the other. When the label is a real text element, use set_text, with newlines for its lines.

      Rules:
      - Refer to elements only by anchor or id exactly as they appear in the index, as a target object {"a": anchor, "id": id, "h": hash}. Never invent anchors or ids. Never estimate the coordinates of an existing element.
      - Prefer the smallest change that satisfies the instruction. Do not touch elements the instruction does not concern.
      - To move, resize or rotate an element use transform (user units); never rewrite its geometry.
      - To recolour one element use set_attr with name fill or stroke on that element. To restyle every element of a class use set_style_rule with a selector like .cls-12. Never touch the style rules unless asked.
      - To add a copy of an existing element use duplicate with an offset. To draw a new shape use insert_shape with a parent anchor, the element kind and its attributes; derive new geometry from the annotation or from a named reference element. New ids must start with a letter, be unique, and follow the naming pattern of their neighbours; when nothing suggests a name, start the id with "ai-".
      - set_text only works on text or tspan elements; outlined labels are renamed as described above, never with set_text.
      - Chairs, plants and other furniture are anonymous shapes inside the room; find them by the inside column, their tag and fill, and their box. "The desk on the left in room 1.03" is the desk (table-... id) inside area-1.03-status with the smallest x.
      - Ids marked protected are bound to bookings; delete, rename or hide them only when the instruction asks for exactly that.
      - Act on the best-supported reading and say in why what you took the words to mean. Return a single ask op only when no element carries the number the instruction names, when several do and nothing else separates them, or when a needed position cannot be derived from any element. When an instruction has several parts, do every part you can and name the rest in summary. If nothing needs to change, return no_change.
      - Every op carries a one-sentence why that names the element's label. summary is one sentence for the person. questions is usually empty.
      Coordinates: user units of the viewBox; x grows to the right, y grows downward.

      Fields each operation carries, besides op and why:
      TEXT

    # One earlier turn of the same edit, oldest first.
    record Turn,
      instruction : String,
      ops : Array(JSON::Any),
      summary : String? = nil,
      resolution : JSON::Any? = nil

    record Options,
      context : JSON::Any,
      instruction : String,
      model : String,
      history : Array(Turn) = [] of Turn,
      image : ImagePart? = nil,
      max_output_tokens : Int32 = MAP_AI_MAX_OUTPUT_TOKENS,
      schema : JSON::Any? = Schema.openai

    def self.build(options : Options) : Request
      context = options.context
      parts = [] of Part

      parts << TextPart.new(index_text(context))

      subtrees = subtrees_text(context)
      parts << TextPart.new(subtrees) unless subtrees.empty?

      if (image = options.image)
        parts << image
      end

      markup = markup_text(context, !options.image.nil?)
      parts << TextPart.new(markup) unless markup.empty?

      history = history_text(options.history)
      parts << TextPart.new(history) unless history.empty?

      parts << TextPart.new("INSTRUCTION\n#{options.instruction.strip}")

      Request.new(
        system: SYSTEM + Schema.reference,
        parts: parts,
        model: options.model,
        max_output_tokens: options.max_output_tokens,
        schema: options.schema,
        schema_name: Schema::OPENAI_NAME,
      )
    end

    # The map's coordinate contract, its style rules, the protected ids and one
    # line per indexed element, capped by bytes with the tail dropped.
    def self.index_text(context : JSON::Any) : String
      String.build do |text|
        text << "MAP\n"
        if (view_box = context["viewBox"]?.try(&.as_a?))
          text << "viewBox: " << view_box.map { |value| number(value) }.join(' ')
          text << " (all coordinates in these user units, origin top-left)\n"
        end
        if (image_px = context["image_px"]?.try(&.as_a?)) && (units = context["units_per_px"]?)
          text << "snapshot: " << image_px.map { |value| number(value) }.join('x')
          text << " px, " << number(units) << " user units per px\n"
        end
        if (stats = context["stats"]?.try(&.as_h?))
          text << "elements: " << stats.map { |key, value| "#{key} #{value}" }.join(", ") << '\n'
        end

        rules = context["style_rules"]?.try(&.as_a?) || [] of JSON::Any
        unless rules.empty?
          text << "style rules: "
          text << capped(rules.compact_map(&.as_s?).join(" "), MAX_STYLE_BYTES) << '\n'
        end

        protected_ids = context["protected_ids"]?.try(&.as_a?) || [] of JSON::Any
        unless protected_ids.empty?
          text << "protected ids (bound to bookings): " << protected_ids.compact_map(&.as_s?).join(", ") << '\n'
        end

        duplicates = context["duplicate_ids"]?.try(&.as_a?) || [] of JSON::Any
        unless duplicates.empty?
          text << "duplicate ids already in the file (not your doing): " << duplicates.compact_map(&.as_s?).join(", ") << '\n'
        end

        text << "\nINDEX\nanchor | id | tag | class | label | fill | bbox(x y w h) | parent | inside | kind | protected | hash\n"
        entries = context["index"]?.try(&.as_a?) || [] of JSON::Any
        used = 0
        shown = 0
        entries.each do |entry|
          line = index_line(entry)
          break if used + line.bytesize > MAX_INDEX_BYTES
          text << line << '\n'
          used += line.bytesize + 1
          shown += 1
        end
        if shown < entries.size
          text << "... #{entries.size - shown} more elements omitted; ask for a narrower selection if the target is not listed\n"
        end

        labels = context["labels"]?.try(&.as_a?) || [] of JSON::Any
        unless labels.empty?
          text << "\nLABELS (outlined; glyph anchors in reading order, the words are on the snapshot)\n"
          labels.each do |label|
            hash = label.as_h? || {} of String => JSON::Any
            anchors = hash["anchors"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
            bbox = hash["bbox"]?.try(&.as_a?).try(&.map { |value| number(value) }.join(' ')) || "-"
            text << "inside " << (hash["in"]?.try(&.as_s?) || "-")
            text << ": " << anchors.size << " glyphs " << anchors.join(' ')
            text << " | bbox " << bbox
            text << " | fill " << (hash["fill"]?.try(&.as_s?) || "-") << '\n'
          end
        end
      end
    end

    private def self.index_line(entry : JSON::Any) : String
      hash = entry.as_h? || {} of String => JSON::Any
      bbox = hash["bbox"]?.try(&.as_a?).try(&.map { |value| number(value) }.join(' ')) || "-"
      label = hash["label"]?.try(&.as_s?)
      [
        hash["a"]?.try(&.as_s?) || "-",
        hash["id"]?.try(&.as_s?) || "-",
        hash["tag"]?.try(&.as_s?) || "-",
        hash["cls"]?.try(&.as_s?).presence || "-",
        label ? %("#{label.gsub('"', "'")}") : "-",
        hash["fill"]?.try(&.as_s?).presence || "-",
        bbox,
        hash["p"]?.try(&.as_s?) || "root",
        hash["in"]?.try(&.as_s?).presence || "-",
        hash["kind"]?.try(&.as_s?) || "-",
        hash["prot"]?.try(&.as_bool?) ? "protected" : "-",
        hash["h"]?.try(&.as_s?) || "-",
      ].join(" | ")
    end

    # The markup of shortlisted elements, each cut at MAX_SUBTREE_EACH and the
    # section at MAX_SUBTREE_BYTES.
    def self.subtrees_text(context : JSON::Any) : String
      subtrees = context["subtrees"]?.try(&.as_h?)
      return "" if subtrees.nil? || subtrees.empty?

      String.build do |text|
        text << "SUBTREES (markup of the shortlisted elements; use these for replace_path, replace_element and as size references)\n"
        used = 0
        subtrees.each do |anchor, markup|
          body = capped(markup.as_s? || markup.to_json, MAX_SUBTREE_EACH)
          block = "[#{anchor}]\n#{body}\n"
          if used + block.bytesize > MAX_SUBTREE_BYTES
            text << "... further subtrees omitted\n"
            break
          end
          text << block
          used += block.bytesize
        end
      end
    end

    # The person's annotations, with the hit-tested candidates under each one,
    # and the selected elements.
    def self.markup_text(context : JSON::Any, with_image : Bool) : String
      markup = context["markup"]?.try(&.as_h?)
      shortlist = context["shortlist"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      return "" if markup.nil? && shortlist.empty?

      String.build do |text|
        if markup
          annotations = markup["annotations"]?.try(&.as_a?) || [] of JSON::Any
          unless annotations.empty?
            text << "ANNOTATIONS drawn by the person, in viewBox units"
            text << "; the numbers match the badges on the snapshot" if with_image
            text << '\n'
            used = 0
            annotations.each do |mark|
              line = annotation_line(mark)
              break if used + line.bytesize > MAX_MARKUP_BYTES
              text << line << '\n'
              used += line.bytesize + 1
            end
          end
          selected = markup["selected"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
          text << "SELECTED by the person: " << selected.join(", ") << '\n' unless selected.empty?
        end
        text << "SHORTLIST (elements under or near the annotations and selection): " << shortlist.join(", ") << '\n' unless shortlist.empty?
      end
    end

    private def self.annotation_line(mark : JSON::Any) : String
      hash = mark.as_h? || {} of String => JSON::Any
      parts = [] of String
      parts << "#{hash["n"]?.try(&.as_i?) || "?"}."
      parts << (hash["kind"]?.try(&.as_s?) || "mark")
      geometry = %w(x y width height x2 y2).compact_map do |key|
        value = hash[key]?
        value && !value.raw.nil? ? "#{key}=#{number(value)}" : nil
      end
      parts.concat(geometry)
      if (points = hash["points"]?.try(&.as_a?))
        parts << "points=" + points.first(40).map { |point| point.as_a?.try(&.map { |value| number(value) }.join(',')) || "?" }.join(' ')
      end
      if (note = hash["text"]?.try(&.as_s?).presence)
        parts << %(text="#{note.gsub('"', "'")}")
      end
      if (hits = hash["hits"]?.try(&.as_a?).try(&.compact_map(&.as_s?))) && !hits.empty?
        parts << "hits: #{hits.join(", ")}"
      end
      if (near = hash["near"]?.try(&.as_a?).try(&.compact_map(&.as_s?))) && !near.empty?
        parts << "near: #{near.join(", ")}"
      end
      parts.join(' ')
    end

    # Earlier turns of this edit: the instruction, the ops answered and what the
    # person did with them.
    def self.history_text(history : Array(Turn)) : String
      return "" if history.empty?

      turns = history.last(MAX_HISTORY_TURNS)
      String.build do |text|
        text << "PREVIOUS TURNS of this edit, oldest first; the map below is its current state, which may already include the applied operations\n"
        used = 0
        turns.each_with_index do |turn, index|
          block = String.build do |entry|
            entry << "Turn #{index + 1} instruction: " << turn.instruction.strip << '\n'
            entry << "Turn #{index + 1} summary: " << turn.summary << '\n' if turn.summary.presence
            entry << "Turn #{index + 1} ops: " << turn.ops.first(MAX_HISTORY_OPS).map { |op| compact_op(op) }.to_json << '\n'
            if (resolution = turn.resolution)
              entry << "Turn #{index + 1} outcome: " << resolution_text(resolution) << '\n'
            else
              entry << "Turn #{index + 1} outcome: not reviewed\n"
            end
          end
          if used + block.bytesize > MAX_HISTORY_BYTES
            text << "... earlier turns omitted\n"
            break
          end
          text << block
          used += block.bytesize
        end
      end
    end

    private def self.resolution_text(resolution : JSON::Any) : String
      hash = resolution.as_h? || {} of String => JSON::Any
      parts = [] of String
      parts << (hash["decision"]?.try(&.as_s?) || "unknown")
      if (accepted = hash["accepted_op_ids"]?.try(&.as_a?)) && !accepted.empty?
        parts << "accepted: #{accepted.compact_map(&.as_s?).join(", ")}"
      end
      if (rejected = hash["rejected_op_ids"]?.try(&.as_a?)) && !rejected.empty?
        parts << "rejected: #{rejected.compact_map(&.as_s?).join(", ")}"
      end
      if (reasons = hash["reasons"]?)
        case raw = reasons.raw
        when Array
          parts << "reasons: #{raw.map(&.to_s).join("; ")}" unless raw.empty?
        when Hash
          parts << "reasons: #{raw.map { |key, value| "#{key}: #{value}" }.join("; ")}" unless raw.empty?
        when String
          parts << "reasons: #{raw}" unless raw.empty?
        end
      end
      parts.join("; ")
    end

    # an op with its null fields and the review bookkeeping dropped
    private def self.compact_op(op : JSON::Any) : Hash(String, JSON::Any)
      hash = op.as_h? || {} of String => JSON::Any
      hash.reject { |key, value| value.raw.nil? || key == "why" }
    end

    private def self.number(value : JSON::Any) : String
      case raw = value.raw
      when Int   then raw.to_s
      when Float then raw == raw.floor ? raw.to_i64.to_s : raw.round(2).to_s
      else            raw.to_s
      end
    end

    private def self.capped(text : String, limit : Int32) : String
      return text if text.bytesize <= limit
      cut = text.byte_slice(0, limit)
      # never split a multibyte character
      cut = cut.scrub("")
      "#{cut}..."
    end
  end
end
