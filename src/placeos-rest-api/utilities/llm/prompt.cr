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

      You are given an index of the map's elements (one line each), the labels the application found, the markup of a few shortlisted elements, sometimes a snapshot image of the map, and an instruction. Anchors are the first column of the index; the id column is the element's id when it has one. The inside column names the smallest room, desk or zone whose box contains the element. The snapshot shows the map as the person sees it, with the ids of the larger rooms and zones printed at their top-left corner and the person's annotations drawn on it.

      Names and ids: rooms, desks, bays and lockers carry their number in their id (area-1.03-status is room 1.03, table-01.004 is desk 01.004, park-100 is bay 100). A name in the instruction such as "Boardroom 1.03" or "desk 01.004" identifies the element whose id carries that number; the words around the number are the label painted on the map, which the snapshot shows.

      Labels: the LABELS section lists every label the application found, of two kinds. A text label is a real text element and its line shows its words: rename it with set_text on that element, keeping its lines (a newline character between lines), and never delete it to insert another. An outlined label is a word drawn as anonymous path elements, one per letter: its line shows the element it sits in (- when it is outside every room), its glyph anchors in reading order, its box and fill; the index marks those elements kind glyph, and the snapshot shows what the label says. To rename an outlined label: delete every glyph anchor of that label, then insert_shape a text element with the new words, after the label's last glyph (the application puts it where the glyphs were), text-anchor middle, x at the centre of the label's box, y at the baseline of the first line (the box's top plus the font size), font-size equal to the box height divided by the number of rows, font-family sans-serif and the label's fill. Preserve the apparent original font weight and style shown in the snapshot; use bold only when the original label is bold. Keep the label's rows: separate lines with a newline character in text and the application lays them out one under the other.

      Finding a label by its words: when the instruction quotes words rather than a number ("Kitchen", "Back Entry/Exit"), look for a text label with those words first; otherwise read the snapshot to see which outlined label shows them, matching each label's box to where the words are drawn. A label inside a room names that room; a label in a corridor or open area names the space around it. Act only on the label whose words match, never on another label nearby.

      Label layout: after changing an overlay colour or opacity, check every label it exposes as well as the edited label. Keep renamed labels centred using their text-anchor and geometry from the shortlist. Do not let renamed or newly visible labels overlap other labels, including existing room names and numbers. Move the edited label into nearby clear space within the same room when needed; preserve labels the user asked to leave unchanged.

      Places: the regions line gives the thirds of the map, so "the top middle of the map" is the top third, horizontally the middle third. The same thirds apply inside a room's box ("the top middle of the Studio"). A copy asked for at a place is offset by the target's centre minus the element's centre so it lands in that region, and stays inside the room's box.

      Rules:
      - Refer to elements only by anchor or id exactly as they appear in the index, as a target object {"a": anchor, "id": id, "h": hash}. Never invent anchors or ids. Never estimate the coordinates of an existing element.
      - Prefer the smallest change that satisfies the instruction. Do not touch elements the instruction does not concern.
      - To move, resize or rotate an element use transform (user units); never rewrite its geometry.
      - After changing a background, fill or overlay, check every label affected by that change against the final visible background. Keep labels unobscured and clearly readable, matching the high-contrast light-on-dark or dark-on-light treatment of neighbouring room labels. Recolour the affected text and tspans, or every glyph of an outlined label, with set_attr when needed; preserve the wording, position and geometry. This readability adjustment is part of the requested edit. Do not recolour a shared class or unrelated labels. Keep the label above the overlay in paint order. Evaluate the composited colour: a dark fill at 0.3 opacity over a light floor produces a light background, so use dark text (for example #24242b), not white.
      - To recolour one element use set_attr with name fill or stroke on that element. To restyle every element of a class use set_style_rule with a selector like .cls-12. Never touch the style rules unless asked.
      - To reference an element created earlier in this same proposal, use its new_id as the target id with a and h null. New elements do not have index anchors yet; never use their id as an anchor. This also applies to parent and after references.
      - To add a copy of an existing element use duplicate with an offset. To draw a new shape use insert_shape with a parent anchor, the element kind and its attributes; derive new geometry from the annotation or from a named reference element. New ids must start with a letter, be unique, and follow the naming pattern of their neighbours; when nothing suggests a name, start the id with "ai-".
      - set_text only works on text or tspan elements; outlined labels are renamed as described above, never with set_text.
      - Chairs, plants and other furniture are anonymous shapes inside the room; find them by the inside column, their tag and fill, and their box. "The desk on the left in room 1.03" is the desk (table-... id) inside area-1.03-status with the smallest x.
      - A drawn object is usually several sibling elements stacked on one spot (a chair: its shadow, its seat and a stroke-only outline). Elements that share a piece value are the layers of one object: delete, move or copy every element of the piece together, with the same offset. A chair at a desk is one piece next to the desk's box; to add chairs, duplicate a whole piece per chair.
      - duplicate keeps the copy in the source element's parent group. For added furniture, choose a complete source piece in the destination room's furniture group; use transform on the copies to rotate them around the new piece centre if the requested orientation differs. Never place a copy in another room while leaving it in the source room's group. A shared furniture layer is suitable only when it already contains the destination furniture. Check the parent chain as well as the inside column. New elements can be targeted by their new_id in later operations. Keep all layers of each chair together and in their original paint order.
      - Desks come in runs. To add desks beside existing ones, duplicate the desk nearest the new position (its table-... element and the chair pieces beside it, all by one offset per new desk); the offset is the spacing between the two nearest desks of that run, so the copies continue the run on the side asked for, and new ids continue the neighbours' numbering (table-01.012 after table-01.011). Copy the desk next to where the new ones go, never a desk in another room, and keep the copies inside the room.
      - A room is bookable when a rect or path with an area-<number>-status id lies over it, in the same parent as the other area-* elements. To make a room bookable, insert_shape such a rect into that parent covering the room (the extent of its walls, or of its label and furniture), with an id following the neighbouring area-* pattern. New booking overlays must preserve visible desks, chairs and other furniture underneath: set fill-opacity to 0.3 explicitly, even when copying a neighbouring room's class. Never copy a solid room fill without adding this transparency. Preserve the furniture unless the instruction explicitly requests its removal. Check labels against the resulting translucent background and use readable contrasting text. Keep existing room overlays unchanged unless asked.
      - Ids marked protected are bound to bookings; delete, rename or hide them only when the instruction asks for exactly that.
      - Act on the best-supported reading and say in why what you took the words to mean. Return a single ask op only when no element carries the number the instruction names, when several do and nothing else separates them, or when a needed position cannot be derived from any element. When an instruction has several parts, do every part you can and name the rest in summary. If nothing needs to change, return no_change.
      - Every op carries a one-sentence why that names the element's label. summary is one sentence for the person stating only what the ops do, and names any part of the instruction that was not done. questions is usually empty.
      - For a shared-wall doorway, use the wall markup supplied in the shortlist to cut the wall geometry itself, retaining all other segments and paint attributes. Do not cover a wall with a floor-coloured rectangle.

      Coordinates: user units of the viewBox; x grows to the right, y grows downward.
      - When the requested new space or its annotation lies outside the viewBox, expanding the canvas is part of that request: emit set_attr on the indexed SVG root with name viewBox and four numbers as its value before adding the room. Take the union of the existing viewBox and all new geometry, including half the wall stroke and a small margin. Keep every existing coordinate unchanged. Never crop the old viewBox or expand either dimension or total area beyond four times its current size. Do not ask for confirmation to show space the person already asked to add.
      - A new room needs a readable name label. If no name was given, use the next room number following neighbouring labels (for example 1.05 after 1.04) and explain it in summary. Match neighbouring text styling, centred inside the new room, above its translucent booking overlay.
      - When a new room adjoins an existing outside wall, make a usable doorway through that shared wall. Use the exact existing wall coordinates and a doorway width matching nearby openings. Preserve every other wall segment. A polyline can be replaced with an equivalent path containing separate subpaths on either side of the doorway; retain its original attributes. Keep the room floor connected to that opening and avoid drawing another wall across the entrance. If the annotation ends within one wall thickness of the existing wall, join the room to that wall.

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
      schema : JSON::Any? = Schema.openai,
      reasoning_effort : String? = "low"

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
        reasoning_effort: options.reasoning_effort,
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
          if view_box.size == 4
            x, y, w, h = view_box.map { |value| value.as_f? || value.as_i64?.try(&.to_f) || 0.0 }
            text << "regions (thirds of the map): left x<" << number(x + w / 3) << ", middle, right x>" << number(x + 2 * w / 3)
            text << "; top y<" << number(y + h / 3) << ", middle, bottom y>" << number(y + 2 * h / 3) << '\n'
          end
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

        text << "\nINDEX\nanchor | id | tag | class | label | fill | bbox(x y w h) | parent | inside | piece | kind | protected | hash\n"
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
          text << "\nLABELS (text labels show their words; outlined labels list glyph anchors in reading order and their words are on the snapshot)\n"
          labels.each { |label| text << label_line(label) << '\n' }
        end
      end
    end

    private def self.label_line(label : JSON::Any) : String
      hash = label.as_h? || {} of String => JSON::Any
      anchors = hash["anchors"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      bbox = hash["bbox"]?.try(&.as_a?).try(&.map { |value| number(value) }.join(' ')) || "-"
      inside = hash["in"]?.try(&.as_s?).presence || "-"
      fill = hash["fill"]?.try(&.as_s?).presence || "-"
      if hash["kind"]?.try(&.as_s?) == "text"
        words = (hash["text"]?.try(&.as_s?) || "").gsub('\n', " / ").gsub('"', "'")
        %(text #{anchors.first? || "-"} "#{words}" | inside #{inside} | bbox #{bbox} | fill #{fill})
      else
        "outlined inside #{inside}: #{anchors.size} glyphs #{anchors.join(' ')} | bbox #{bbox} | fill #{fill}"
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
        hash["piece"]?.try(&.as_s?).presence || "-",
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
            if with_image && (image_bounds = markup["viewBox"]?.try(&.as_a?))
              text << "SNAPSHOT bounds in user units: " << image_bounds.map { |value| number(value) }.join(' ') << "; these may include annotations outside the map canvas.\n"
            end
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

    # `request` again with its answer's rejected operations and the reasons,
    # asking for the whole proposal corrected. Nothing from the answer was
    # applied, so the map in the request is still the current state.
    def self.repair(request : Request, envelope : Ops::Envelope, issues : Hash(String, String)) : Request
      answered = envelope.ops.map_with_index do |op, position|
        {"op_id" => JSON::Any.new(Ops.id_for(position))}.merge(compact_op(op))
      end
      text = String.build do |io|
        io << "REPAIR\n"
        io << "Your previous answer to this request has not been applied: the application rejected the operations listed under REJECTED, so the map is exactly as described above. "
        io << "Answer again with the whole corrected proposal. Keep every operation that was not rejected as it was, fix each rejected operation or leave it out, and add nothing else.\n"
        io << "PREVIOUS ANSWER summary: " << envelope.summary << '\n' if envelope.summary.presence
        io << "PREVIOUS ANSWER ops: " << answered.to_json << '\n'
        io << "REJECTED\n"
        issues.each { |id, reason| io << id << ": " << reason << '\n' }
      end
      request.copy_with(parts: request.parts + [TextPart.new(text)] of Part)
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

    private def self.number(value : Float64) : String
      value == value.floor ? value.to_i64.to_s : value.round(2).to_s
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
