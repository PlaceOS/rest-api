require "./helper"

module PlaceOS::Api
  def self.assert_strict_objects(node : JSON::Any) : Nil
    if (hash = node.as_h?)
      if hash["properties"]?
        hash["additionalProperties"].as_bool.should be_false
        hash["required"].as_a.map(&.as_s).sort!.should eq hash["properties"].as_h.keys.sort!
      end
      hash.each_value { |value| assert_strict_objects(value) }
    elsif (list = node.as_a?)
      list.each { |value| assert_strict_objects(value) }
    end
  end

  def self.op(json : String) : Hash(String, JSON::Any)
    JSON.parse(json).as_h
  end

  describe Llm::Prompt do
    context = JSON.parse(File.read(File.join(__DIR__, "fixtures/map_ai/context.json")))
    image = Llm::ImagePart.new(bytes: Bytes[0x89, 0x50, 0x4E, 0x47], mime: "image/png")

    it "sends the rules, the op reference and the schema first, the instruction last" do
      request = Llm::Prompt.build(Llm::Prompt::Options.new(
        context: context,
        instruction: "Make meeting room 1.01 light green.",
        model: "gpt-5.4-mini",
      ))

      request.system.should contain "You edit SVG floor-plan maps"
      request.system.should contain "set_attr: target, name, value"
      request.system.should contain "Preserve the apparent original font weight and style shown in the snapshot"
      request.system.should contain "use bold only when the original label is bold"
      request.system.should contain "set fill-opacity to 0.3 explicitly"
      request.system.should contain "Preserve the furniture unless the instruction explicitly requests its removal"
      request.system.should contain "expanding the canvas is part of that request"
      request.system.should contain "Never crop the old viewBox"
      request.system.should contain "A new room needs a readable name label"
      request.system.should contain "make a usable doorway through that shared wall"
      request.schema.should_not be_nil
      request.model.should eq "gpt-5.4-mini"
      request.max_output_tokens.should eq MAP_AI_MAX_OUTPUT_TOKENS

      text = request.text
      text.index!("MAP\n").should be < text.index!("INDEX\n")
      text.index!("INDEX\n").should be < text.index!("SUBTREES")
      text.index!("SUBTREES").should be < text.index!("ANNOTATIONS")
      text.index!("ANNOTATIONS").should be < text.index!("INSTRUCTION\n")
      text.should end_with "INSTRUCTION\nMake meeting room 1.01 light green."

      # the index carries what the model may ground on, nothing else
      text.should contain "viewBox: 0 0 1725.26 619"
      text.should contain "protected ids (bound to bookings): table-01.004, area-1.02-status"
      text.should contain "e4 | table-01.004 | rect | cls-12 | \"Desk 01.004\" | - | 640 420 30 20 | e1 | - | - | bookable | protected | d4d4d4d4"
      text.should contain "e7 | - | path | cls-1 | - | - | 0 0 1725.26 4 | e1 | - | - | art | - | 07070707"
      text.should contain ".cls-12{fill:#d1d3d4}"
      text.should contain "[e4]\n<rect id=\"table-01.004\""
      text.should contain "1. box x=630 y=410 width=90 height=40 hits: e4, e5 near: e7"
      text.should contain %(2. pin x=160 y=120 text="this room" hits: e2)
      text.should contain "SELECTED by the person: area-1.01-status"
      text.should contain "SHORTLIST (elements under or near the annotations and selection): e2, e4"
    end

    it "puts the image after the subtrees and before the annotations" do
      request = Llm::Prompt.build(Llm::Prompt::Options.new(
        context: context,
        instruction: "Add a desk here.",
        model: "gpt-5.4-mini",
        image: image,
      ))

      kinds = request.parts.map { |part| part.is_a?(Llm::ImagePart) ? "image" : part.as(Llm::TextPart).text.lines.first }
      kinds.index!("image").should be > kinds.index!(&.starts_with?("SUBTREES"))
      annotations_position = request.parts.index! do |part|
        part.is_a?(Llm::TextPart) && part.text.includes?("ANNOTATIONS drawn by the person")
      end
      kinds.index!("image").should be < annotations_position
      request.text.should contain "SNAPSHOT bounds in user units:"
      request.text.should contain "these may include annotations outside the map canvas"
      request.images.size.should eq 1
      request.text.should contain "the numbers match the badges on the snapshot"
    end

    it "includes the parent chain, oldest first, with what the person did" do
      first = Llm::Prompt::Turn.new(
        instruction: "Make meeting room 1.01 light green.",
        ops: [JSON.parse(%({"id":"op-1","op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"fill","value":"#90ee90","why":"recolours Meeting 1.01","selector":null}))],
        summary: "Recoloured Meeting 1.01.",
        resolution: JSON.parse(%({"decision":"rejected","accepted_op_ids":[],"rejected_op_ids":["op-1"],"reasons":{"op-1":"wrong green"}})),
      )
      second = Llm::Prompt::Turn.new(instruction: "Use a paler green.", ops: [] of JSON::Any)

      request = Llm::Prompt.build(Llm::Prompt::Options.new(
        context: context,
        instruction: "Paler still.",
        model: "gpt-5.4-mini",
        history: [first, second],
      ))

      text = request.text
      text.index!("PREVIOUS TURNS").should be > text.index!("INDEX\n")
      text.index!("PREVIOUS TURNS").should be < text.index!("INSTRUCTION\n")
      text.index!("Turn 1 instruction").should be < text.index!("Turn 2 instruction")
      text.should contain "Turn 1 outcome: rejected; rejected: op-1; reasons: op-1: wrong green"
      text.should contain "Turn 2 outcome: not reviewed"
      # the null fields and the why are not worth the tokens
      text.should contain %("op":"set_attr")
      text.should_not contain %("selector":null)
      text.should_not contain "recolours Meeting 1.01"
    end

    it "caps the index, the subtrees and the history" do
      big = JSON.parse(context.to_json)
      index = big["index"].as_a
      3000.times do |n|
        index << JSON.parse(%({"a":"x#{n}","id":null,"tag":"path","cls":"cls-1","label":null,"bbox":[#{n},#{n},10,10],"p":"e1","z":#{n},"kind":"art","prot":false,"h":"#{n.to_s.rjust(8, '0')}"}))
      end
      subtrees = big["subtrees"].as_h
      12.times { |n| subtrees["s#{n}"] = JSON::Any.new("<path d=\"#{"M0 0 l1 1 " * 2000}\"/>") }

      history = Array.new(10) do |n|
        Llm::Prompt::Turn.new(instruction: "turn #{n}", ops: [] of JSON::Any)
      end

      request = Llm::Prompt.build(Llm::Prompt::Options.new(
        context: big,
        instruction: "x",
        model: "gpt-5.4-mini",
        history: history,
      ))

      index_text = Llm::Prompt.index_text(big)
      index_text.bytesize.should be < Llm::Prompt::MAX_INDEX_BYTES + 2_000
      index_text.should contain "more elements omitted"
      # the front of the index survives, the tail goes
      index_text.should contain "e4 | table-01.004"

      subtree_text = Llm::Prompt.subtrees_text(big)
      subtree_text.bytesize.should be < Llm::Prompt::MAX_SUBTREE_BYTES + 2_000
      subtree_text.should contain "further subtrees omitted"

      text = request.text
      text.should_not contain "Turn 7 instruction"
      text.should contain "turn 9"
      text.should_not contain "turn 0"
    end

    it "leaves out sections the context does not carry" do
      bare = JSON.parse(%({"schema":"placeos.map-ai-context/1","index":[]}))
      request = Llm::Prompt.build(Llm::Prompt::Options.new(context: bare, instruction: "Nothing.", model: "m"))
      request.parts.size.should eq 2
      request.text.should_not contain "SUBTREES"
      request.text.should_not contain "ANNOTATIONS"
    end
  end

  describe Llm::Schema do
    it "sends the vendor the editor's ops-schema.json as it is" do
      source = JSON.parse(File.read(File.join(__DIR__, "../src/placeos-rest-api/utilities/llm/ops-schema.json")))
      schema = Llm::Schema.openai
      schema.should eq source

      schema["type"].as_s.should eq "object"
      schema["additionalProperties"].as_bool.should be_false
      schema["required"].as_a.map(&.as_s).should eq ["schema_version", "summary", "ops", "questions"]
      schema["properties"]["schema_version"]["enum"].as_a.map(&.as_i).should eq [Llm::Schema::VERSION]

      variants = schema["properties"]["ops"]["items"]["anyOf"].as_a
      variants.map(&.["properties"].["op"].["enum"].[0].as_s).should eq Llm::Schema::OPS
      variants.each do |variant|
        variant["additionalProperties"].as_bool.should be_false
        variant["required"].as_a.map(&.as_s).should eq variant["properties"].as_h.keys
        variant["properties"]["why"]["type"].as_s.should eq "string"
      end

      schema["$defs"]["target"]["required"].as_a.map(&.as_s).should eq ["a", "id", "h"]
      schema["$defs"]["name_value"]["required"].as_a.map(&.as_s).should eq ["name", "value"]
      # every object anywhere in the tree is closed and fully required
      PlaceOS::Api.assert_strict_objects(schema)

      request = Llm::Prompt.build(Llm::Prompt::Options.new(context: JSON.parse(%({"index":[]})), instruction: "x", model: "m"))
      request.schema.should eq source
      request.schema_name.should eq "map_edit"
    end

    it "derives the vocabulary from the schema" do
      Llm::Schema::OPS.should eq %w(set_attr set_style_rule set_text transform delete duplicate insert_shape set_id reorder group ungroup replace_element replace_path no_change ask)
      Llm::Schema::FIELDS_BY_OP["set_attr"].should eq %w(target name value)
      Llm::Schema::FIELDS_BY_OP["set_style_rule"].should eq %w(selector declarations)
      Llm::Schema::FIELDS_BY_OP["insert_shape"].should eq %w(parent after kind attrs new_id text)
      Llm::Schema::SHAPES.should eq %w(rect circle ellipse line polygon polyline path text g)
      Llm::Schema::POSITIONS.should eq %w(first last)
      Llm::Schema.reference.should contain "duplicate: target, new_id, translate, count, id_pattern\n"
      Llm::Schema.reference.should contain "ask: question\n"

      Llm::Schema.valid_id?("table-01.018").should be_true
      Llm::Schema.valid_id?("1abc").should be_false
      Llm::Schema.valid_id?("ai desk").should be_false
      Llm::Schema.allowed_attribute?("data-name").should be_true
      Llm::Schema.allowed_attribute?("data-map-editor-anchor").should be_false
      Llm::Schema.allowed_attribute?("data-").should be_false
      Llm::Schema.allowed_attribute?("onclick").should be_false
      Llm::Schema.allowed_attribute?("href").should be_false
      Llm::Schema.allowed_attribute?("transform").should be_false
    end
  end

  describe Llm::Values do
    it "checks attribute values the way the editor does" do
      Llm::Values.attribute_value_issue("fill", "#90ee90").should be_nil
      Llm::Values.attribute_value_issue("fill", "lightblue").should be_nil
      Llm::Values.attribute_value_issue("fill", "rgba(0, 0, 255, 0.45)").should be_nil
      Llm::Values.attribute_value_issue("fill", "url(#grad) none").should be_nil
      Llm::Values.attribute_value_issue("fill", "#f28c28.").should eq %("#f28c28." is not a colour)
      Llm::Values.attribute_value_issue("fill", "#008000 garbage").should eq %("#008000 garbage" is not a colour)
      Llm::Values.attribute_value_issue("stroke", "url(http://evil.example/p.svg#g)").should eq %("url(http://evil.example/p.svg#g)" is not a colour)
      Llm::Values.attribute_value_issue("stroke-width", "1.5px").should be_nil
      Llm::Values.attribute_value_issue("stroke-width", "thick").should eq %("thick" is not a length)
      Llm::Values.attribute_value_issue("opacity", "0.6").should be_nil
      Llm::Values.attribute_value_issue("opacity", "60%").should be_nil
      Llm::Values.attribute_value_issue("opacity", "1.5").should eq %("1.5" is not an opacity between 0 and 1)
      Llm::Values.attribute_value_issue("stroke-dasharray", "4 2").should be_nil
      Llm::Values.attribute_value_issue("stroke-dasharray", "4 two").should eq %("4 two" is not a dash array)
      Llm::Values.attribute_value_issue("class", "cls-12 desk").should be_nil
      Llm::Values.attribute_value_issue("class", "12cls").should eq %("12cls" is not a class list)
      Llm::Values.attribute_value_issue("visibility", "hidden").should be_nil
      Llm::Values.attribute_value_issue("font-family", "Arial, sans-serif").should be_nil
      Llm::Values.attribute_value_issue("font-family", "url(x)").should eq %("url(x)" is not a font family)
      Llm::Values.attribute_value_issue("font-weight", "700").should be_nil
      Llm::Values.attribute_value_issue("font-weight", "heavy").should eq %("heavy" is not a font weight)
      Llm::Values.attribute_value_issue("text-anchor", "middle").should be_nil
      Llm::Values.attribute_value_issue("data-name", "Boardroom").should be_nil
      Llm::Values.attribute_value_issue("data-name", "<b>x</b>").should eq "data-name may not contain markup"
    end

    it "checks geometry and path data" do
      Llm::Values.geometry_value_issue("x", "12.5").should be_nil
      Llm::Values.geometry_value_issue("x", "12px").should eq %(x="12px" is not a number)
      Llm::Values.geometry_value_issue("points", "0,0 10,0 10,10").should be_nil
      Llm::Values.geometry_value_issue("points", "0,0 10").should eq %("0,0 10" is not a points list)
      Llm::Values.path_data_issue("M100 80h120v90h-120z").should be_nil
      Llm::Values.path_data_issue("M0 0 C1 1 2 2 3 3 Z").should be_nil
      Llm::Values.path_data_issue("").should eq "empty path data"
      Llm::Values.path_data_issue("L10 10").should eq "path must start with M"
      Llm::Values.path_data_issue("M0 0 L10").should eq "command L has a partial argument group"
      Llm::Values.path_data_issue("M0 0 X").should eq %(unexpected characters "X")
      Llm::Values.path_data_issue("10 M0 0").should eq "number before the first command"
      Llm::Values.path_data_issue("M0 0 Z 1").should eq "Z takes no arguments"
    end

    it "spots unsafe CSS, escapes included" do
      Llm::Values.unsafe_css?("fill: #eee").should be_false
      Llm::Values.unsafe_css?("fill: url(#grad)").should be_false
      Llm::Values.unsafe_css?("fill: url(http://evil)").should be_true
      Llm::Values.unsafe_css?("behavior: url(x.htc)").should be_true
      Llm::Values.unsafe_css?("width: expression(1)").should be_true
      Llm::Values.unsafe_css?("fill: u\\72l(http://evil)").should be_true
      Llm::Values.external_url?("url(#grad)").should be_false
      Llm::Values.external_url?("url( 'http://x' )").should be_true
    end
  end

  describe Llm::Ops do
    context = JSON.parse(File.read(File.join(__DIR__, "fixtures/map_ai/context.json")))

    it "reads fenced JSON and refuses prose" do
      envelope = Llm::Ops.parse("```json\n{\"schema_version\":1,\"summary\":\"s\",\"ops\":[],\"questions\":[\"which?\"]}\n```")
      envelope.summary.should eq "s"
      envelope.ops.should be_empty
      envelope.questions.should eq ["which?"]

      expect_raises(Error::ImageGen::InvalidResponse, "did not answer with JSON") do
        Llm::Ops.parse("I would change the fill of the boardroom.")
      end
      expect_raises(Error::ImageGen::InvalidResponse, "no ops list") do
        Llm::Ops.parse(%({"summary":"s"}))
      end
      expect_raises(Error::ImageGen::InvalidResponse, "empty") { Llm::Ops.parse("") }
    end

    # the fixture: e1 <g> walls, e2 path area-1.01-status, e3 path area-1.02-status (protected),
    # e4 rect table-01.004 (protected), e5 rect table-01.005, e6 text label-1.01, e7 path
    it "flags the ops that fail a check, by id, and leaves every op as it came" do
      cases = [
        { %({"op":"set_attr","target":{"a":"e2","id":"area-1.01-status","h":"b2b2b2b2"},"name":"fill","value":"#90ee90","why":"w"}), nil },
        { %({"op":"set_attr","target":{"a":"e2","id":"","h":""},"name":"fill","value":"#90ee90","why":"w"}), nil },
        { %({"op":"set_attr","target":{"a":"","id":"area-1.01-status","h":"b2b2b2b2"},"name":"fill","value":"#90ee90","why":"w"}), nil },
        { %({"op":"set_attr","target":{"a":"","id":"","h":""},"name":"fill","value":"#90ee90","why":"w"}), "target names neither an anchor nor an id" },
        { %({"op":"set_attr","target":{"a":"e2","id":"","h":"stale"},"name":"fill","value":"#90ee90","why":"w"}), "the element changed since the index was built (hash mismatch)" },
        { %({"op":"set_attr","target":{"a":"e99","id":null,"h":null},"name":"fill","value":"#90ee90","why":"w"}), "anchor e99 is not in the index" },
        { %({"op":"set_attr","target":{"a":"e2","id":"table-01.004","h":null},"name":"fill","value":"#000","why":"w"}), "anchor e2 and id table-01.004 are different elements" },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":"stale"},"name":"fill","value":"#000","why":"w"}), "the element changed since the index was built (hash mismatch)" },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"onclick","value":"x","why":"w"}), "attribute onclick may not be set" },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"data-name","value":"Boardroom","why":"w"}), nil },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"data-map-editor-anchor","value":"e9","why":"w"}), "attribute data-map-editor-anchor may not be set" },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"visibility","value":"display:none","why":"w"}), %("display:none" is not a visibility keyword) },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"fill","value":"#f28c28.","why":"w"}), %("#f28c28." is not a colour) },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"fill","value":"url(http://evil.example/p.svg#g)","why":"w"}), %("url(http://evil.example/p.svg#g)" is not a colour) },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"fill","value":"url(#grad)","why":"w"}), nil },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"fill","value":null,"why":"w"}), nil },
        { %({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"opacity","value":"1.5","why":"w"}), %("1.5" is not an opacity between 0 and 1) },
        { %({"op":"set_text","target":{"a":"e2","id":null,"h":null},"text":"x","why":"w"}), "set_text only applies to text and tspan elements" },
        { %({"op":"set_text","target":{"a":"e6","id":null,"h":null},"text":"Boardroom","why":"w"}), nil },
        { %({"op":"transform","target":{"a":"e5","id":null,"h":null},"targets":null,"translate":[20,0],"scale":null,"rotate":null,"origin":null,"why":"w"}), nil },
        { %({"op":"transform","target":{"a":"e5","id":null,"h":null},"targets":null,"translate":null,"scale":null,"rotate":null,"origin":null,"why":"w"}), "transform needs translate, scale or rotate" },
        { %({"op":"transform","target":null,"targets":[{"a":"e4","id":null,"h":null},{"a":"e5","id":null,"h":null}],"translate":[20],"scale":null,"rotate":null,"origin":null,"why":"w"}), "translate must be [dx, dy]" },
        { %({"op":"transform","target":{"a":"e5","id":null,"h":null},"targets":null,"translate":null,"scale":null,"rotate":"90","origin":null,"why":"w"}), "rotate must be a number" },
        { %({"op":"transform","target":null,"targets":null,"translate":[1,1],"scale":null,"rotate":null,"origin":null,"why":"w"}), "no target given" },
        { %({"op":"delete","target":{"a":"e4","id":null,"h":null},"targets":null,"why":"w"}), nil },
        { %({"op":"delete","target":null,"targets":null,"why":"w"}), "no target given" },
        { %({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":"table-01.006","translate":[40,0],"count":2,"id_pattern":null,"why":"w"}), nil },
        { %({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":"table-01.004","translate":[40,0],"count":null,"id_pattern":null,"why":"w"}), "table-01.004 is already an id in the map" },
        { %({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":"1bad","translate":[40,0],"count":null,"id_pattern":null,"why":"w"}), %("1bad" is not a valid id) },
        { %({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":null,"translate":null,"count":null,"id_pattern":null,"why":"w"}), "duplicate needs translate" },
        { %({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":null,"translate":[40,0],"count":2.5,"id_pattern":null,"why":"w"}), "count must be a whole number" },
        { %({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":null,"translate":[40,0],"count":41,"id_pattern":null,"why":"w"}), "count must be between 1 and 40" },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"rect","attrs":[{"name":"x","value":"1"},{"name":"width","value":"30"},{"name":"fill","value":"#fff"}],"new_id":"ai-desk-1","text":null,"why":"w"}), nil },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"rect","attrs":[],"new_id":"ai-desk-1","text":null,"why":"w"}), "ai-desk-1 is used twice in this answer" },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"script","attrs":[],"new_id":null,"text":null,"why":"w"}), "script is not a shape that can be inserted" },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"rect","attrs":[{"name":"onload","value":"x"}],"new_id":null,"text":null,"why":"w"}), "attribute onload is not allowed on a rect" },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"rect","attrs":[{"name":"transform","value":"rotate(9)"}],"new_id":null,"text":null,"why":"w"}), "attribute transform is not allowed on a rect" },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"rect","attrs":[{"name":"x","value":"abc"}],"new_id":null,"text":null,"why":"w"}), %(x="abc" is not a number) },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"text","attrs":[{"name":"dx","value":"4"}],"new_id":null,"text":"Hi","why":"w"}), nil },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"path","attrs":[{"name":"d","value":"M0 0 L10 10 Z"}],"new_id":null,"text":null,"why":"w"}), nil },
        { %({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"after":null,"kind":"polygon","attrs":[{"name":"points","value":"0,0 10,0 10"}],"new_id":null,"text":null,"why":"w"}), %("0,0 10,0 10" is not a points list) },
        { %({"op":"insert_shape","parent":{"a":"e99","id":null,"h":null},"after":null,"kind":"g","attrs":[],"new_id":null,"text":null,"why":"w"}), "parent: anchor e99 is not in the index" },
        { %({"op":"set_style_rule","selector":".cls-12","declarations":[{"name":"fill","value":"#eee"},{"name":"stroke","value":"#333"}],"why":"w"}), nil },
        { %({"op":"set_style_rule","selector":"*","declarations":[{"name":"fill","value":"#eee"}],"why":"w"}), %(the selector "*" is not allowed) },
        { %({"op":"set_style_rule","selector":".a{} @import url(http://evil); .b","declarations":[{"name":"fill","value":"#eee"}],"why":"w"}), %(the selector ".a{} @import url(http://evil); .b" is not allowed) },
        { %({"op":"set_style_rule","selector":".cls-12","declarations":[{"name":"background","value":"url(http://x)"}],"why":"w"}), "property background may not be set" },
        { %({"op":"set_style_rule","selector":".cls-12","declarations":[{"name":"fill","value":"url(http://x)"}],"why":"w"}), "the value of fill is not allowed" },
        { %({"op":"set_style_rule","selector":".cls-12","declarations":[{"name":"fill","value":"#eee } svg { visibility: hidden"}],"why":"w"}), %("#eee } svg { visibility: hidden" is not a colour) },
        { %({"op":"set_style_rule","selector":".cls-12","declarations":[{"name":"fill","value":"u\\\\72l(http://evil)"}],"why":"w"}), "the value of fill is not allowed" },
        { %({"op":"set_style_rule","selector":".cls-12","declarations":"fill: #eee","why":"w"}), "set_style_rule needs declarations" },
        { %({"op":"set_style_rule","selector":".cls-12","declarations":[],"why":"w"}), "set_style_rule needs declarations" },
        { %({"op":"set_id","target":{"a":"e5","id":null,"h":null},"new_id":"table-01.005-renamed","why":"w"}), nil },
        { %({"op":"set_id","target":{"a":"e5","id":null,"h":null},"new_id":null,"why":"w"}), nil },
        { %({"op":"reorder","target":{"a":"e5","id":null,"h":null},"before":null,"after":null,"position":"last","why":"w"}), nil },
        { %({"op":"reorder","target":{"a":"e5","id":null,"h":null},"before":null,"after":null,"position":null,"why":"w"}), "reorder needs exactly one of before, after or position" },
        { %({"op":"reorder","target":{"a":"e5","id":null,"h":null},"before":{"a":"e4","id":null,"h":null},"after":null,"position":"first","why":"w"}), "reorder needs exactly one of before, after or position" },
        { %({"op":"group","targets":[{"a":"e4","id":null,"h":null},{"a":"e5","id":null,"h":null}],"new_id":"ai-desks","why":"w"}), nil },
        { %({"op":"group","targets":[],"new_id":null,"why":"w"}), "group needs targets" },
        { %({"op":"ungroup","target":{"a":"e5","id":null,"h":null},"why":"w"}), "ungroup only applies to a group" },
        { %({"op":"ungroup","target":{"a":"e1","id":null,"h":null},"why":"w"}), nil },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<path id=\\"area-1.01-status\\" class=\\"cls-3\\" d=\\"M0 0h1v1z\\"/>","why":"w"}), nil },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<g><rect onload=\\"alert(1)\\"/></g>","why":"w"}), "attribute onload is not allowed" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect/><rect/>","why":"w"}), "the markup must be exactly one element" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<a href=\\"http://x\\"><rect/></a>","why":"w"}), "href must reference an id in the document" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<a href=\\"#x\\"><rect/></a>","why":"w"}), nil },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<image href=\\"data:image/png;base64,AAAA\\" width=\\"1\\" height=\\"1\\"/>","why":"w"}), nil },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<image href=\\"http://evil.example/x.png\\"/>","why":"w"}), "href must reference an id in the document" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect xlink:href=\\"http://evil.example/\\"/>","why":"w"}), "xlink:href must reference an id in the document" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect style=\\"fill:url(#grad)\\"/>","why":"w"}), nil },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect style=\\"fill:url(http://evil.example/p.svg#g)\\"/>","why":"w"}), "style contains an unsafe value" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect style=\\"fill:u\\\\72l(http://evil)\\"/>","why":"w"}), "style contains an unsafe value" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect fill=\\"url(http://evil.example/p.svg#g)\\"/>","why":"w"}), "fill may not reference anything outside the document" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<g><style>.room{visibility:hidden}</style><rect/></g>","why":"w"}), "<style> is not allowed" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<svg><script>alert(1)</script></svg>","why":"w"}), "<script> is not allowed" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<set attributeName=\\"x\\" onbegin=\\"alert(1)\\"/>","why":"w"}), "<set> is not allowed" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<animateColor/>","why":"w"}), "<animateColor> is not allowed" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<use href=\\"#x\\"/>","why":"w"}), "<use> is not allowed" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect ONLOAD=\\"x\\"/>","why":"w"}), "attribute ONLOAD is not allowed" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<x:rect xmlns:x=\\"http://example.com/x\\"/>","why":"w"}), "<rect> is outside the SVG namespace" },
        { %({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect>&xxe;</rect>","why":"w"}), "the markup does not parse" },
        { %({"op":"replace_path","target":{"a":"e2","id":null,"h":null},"d":"M0 0 L10 10 Z","why":"w"}), nil },
        { %({"op":"replace_path","target":{"a":"e5","id":null,"h":null},"d":"M0 0","why":"w"}), "replace_path only applies to a path" },
        { %({"op":"replace_path","target":{"a":"e2","id":null,"h":null},"d":"L10 10","why":"w"}), "path must start with M" },
        { %({"op":"no_change","reason":"nothing to do","why":"w"}), nil },
        { %({"op":"ask","question":"which room?","why":"w"}), nil },
        { %({"op":"ask","why":"w"}), "ask needs a question" },
        { %({"op":"explode","why":"w"}), %(unknown operation "explode") },
      ] of Tuple(String, String?)

      # in answers of at most MAP_AI_MAX_OPS, so the op limit stays out of the way
      cases.each_slice(60) do |answer|
        checked = Llm::Ops.check(answer.map { |json, _| JSON.parse(json) }, context)
        checked.ops.size.should eq answer.size
        # stored as the model sent them: no bookkeeping on the op
        checked.ops.first.as_h.keys.should eq JSON.parse(answer.first[0]).as_h.keys

        answer.each_with_index do |(json, expected), position|
          actual = checked.issues["op-#{position + 1}"]?
          if expected
            actual.should_not be_nil, "#{json} should have been flagged #{expected.inspect}"
            actual.to_s.should start_with(expected), "#{json}: got #{actual.inspect}"
          else
            actual.should be_nil, "#{json} was flagged #{actual.inspect}"
          end
        end
      end
    end

    it "only accepts finite canvas bounds on the indexed SVG root" do
      canvas_context = JSON.parse(%({"index":[{"a":"e0","tag":"svg","kind":"root"},{"a":"e1","tag":"svg","kind":"art"},{"a":"e2","tag":"rect","kind":"art"}]}))
      values = ["0 0 100 100", "-20 -30 120 130", "0,0,100,100", "0 0 -100 100", "0 0 100 0", "0 0 100", "0 rubbish 0 100 100", "0 0 NaN 100", "0 0 Infinity 100", "0 0 1e999 100"]
      ops = values.map do |value|
        JSON.parse({"op" => "set_attr", "target" => {"a" => "e0"}, "name" => "viewBox", "value" => value}.to_json)
      end
      ops << JSON.parse(%({"op":"set_attr","target":{"a":"e0"},"name":"viewBox","value":null}))
      ops << JSON.parse(%({"op":"set_attr","target":{"a":"e1"},"name":"viewBox","value":"0 0 100 100"}))
      ops << JSON.parse(%({"op":"set_attr","target":{"a":"e2"},"name":"viewBox","value":"0 0 100 100"}))
      checked = Llm::Ops.check(ops, canvas_context)
      checked.issues.keys.should eq (4..13).map { |n| "op-#{n}" }
      checked.issues["op-12"].should eq "canvas bounds can only be changed on the SVG root"
      checked.issues["op-13"].should eq "canvas bounds can only be changed on the SVG root"
    end

    it "only accepts canvas bounds that keep the old map and stay within four times its size" do
      canvas_context = JSON.parse(%({"viewBox":[0,0,100,100],"index":[{"a":"e0","tag":"svg","kind":"root"}]}))
      values = ["0 0 100 100", "-50 -50 200 200", "0 -100 100 200", "10 0 100 100", "0 0 90 100", "0 0 500 100", "-100 -100 300 300"]
      ops = values.map do |value|
        JSON.parse({"op" => "set_attr", "target" => {"a" => "e0"}, "name" => "viewBox", "value" => value}.to_json)
      end
      checked = Llm::Ops.check(ops, canvas_context)
      checked.issues.should eq({
        "op-4" => "the canvas may expand but cannot crop the existing map",
        "op-5" => "the canvas may expand but cannot crop the existing map",
        "op-6" => "the canvas expansion exceeds four times the existing size",
        "op-7" => "the canvas expansion exceeds four times the existing size",
      })
    end

    it "resolves explicit ids created earlier in a proposal without accepting forward references" do
      created_context = JSON.parse(%({"index":[{"a":"e1","id":"chair","tag":"path"}]}))
      ops = [
        %({"op":"transform","target":{"id":"ai-chair"},"rotate":90}),
        %({"op":"duplicate","target":{"a":"e1"},"new_id":"ai-chair","translate":[20,0]}),
        %({"op":"transform","target":{"id":"ai-chair"},"rotate":90}),
        %({"op":"set_text","target":{"id":"ai-chair"},"text":"wrong kind"}),
        %({"op":"insert_shape","kind":"text","new_id":"ai-label","attrs":[],"text":"Room"}),
        %({"op":"set_text","target":{"id":"ai-label"},"text":"New room"}),
        %({"op":"insert_shape","kind":"script","new_id":"ai-invalid","attrs":[]}),
        %({"op":"transform","target":{"id":"ai-invalid"},"rotate":90}),
      ].map { |op| JSON.parse(op) }
      checked = Llm::Ops.check(ops, created_context)
      checked.issues.keys.should eq ["op-1", "op-4", "op-7", "op-8"]
      checked.issues["op-4"].should eq "set_text only applies to text and tspan elements"
    end

    it "rejects duplicate suffix collisions without claiming or registering the other copies" do
      created_context = JSON.parse(%({"index":[{"a":"e1","id":"chair","tag":"path"},{"a":"e2","id":"ai-chair-2","tag":"path"}]}))
      ops = [
        %({"op":"duplicate","target":{"a":"e1"},"new_id":"ai-chair","count":3,"translate":[20,0]}),
        %({"op":"transform","target":{"id":"ai-chair"},"rotate":90}),
        %({"op":"transform","target":{"id":"ai-chair-3"},"rotate":90}),
        %({"op":"duplicate","target":{"a":"e1"},"new_id":"ai-chair","translate":[20,0]}),
        %({"op":"transform","target":{"id":"ai-chair"},"rotate":90}),
        %({"op":"duplicate","target":{"a":"e1"},"new_id":"new-chair","count":2,"translate":[20,0]}),
        %({"op":"transform","target":{"id":"new-chair-2"},"rotate":90}),
      ].map { |op| JSON.parse(op) }
      checked = Llm::Ops.check(ops, created_context)
      checked.issues.keys.should eq ["op-1", "op-2", "op-3"]
      checked.issues["op-1"].should eq "ai-chair-2 is already an id in the map"
    end

    it "renumbers rooms sequentially and reuses the freed id for a new room" do
      rename_context = JSON.parse(%({"index":[{"a":"e1","id":"room-04","tag":"rect"},{"a":"e2","id":"room-05","tag":"rect"}]}))
      ops = [
        %({"op":"set_id","target":{"a":"e2","id":"room-05"},"new_id":"room-06"}),
        %({"op":"set_id","target":{"a":"e1","id":"room-04"},"new_id":"room-05"}),
        %({"op":"insert_shape","kind":"rect","new_id":"room-04","attrs":[]}),
        %({"op":"set_attr","target":{"id":"room-06"},"name":"fill","value":"red"}),
      ].map { |op| JSON.parse(op) }
      Llm::Ops.check(ops, rename_context).issues.should be_empty
      rename_context["index"][0]["id"].as_s.should eq "room-04"
      rename_context["index"][1]["id"].as_s.should eq "room-05"
    end

    it "swaps ids through a temporary id and releases earlier claimed ids" do
      rename_context = JSON.parse(%({"index":[{"a":"e1","id":"zone-a","tag":"g"},{"a":"e2","id":"zone-b","tag":"g"}]}))
      ops = [
        %({"op":"set_id","target":{"a":"e1"},"new_id":"temp-zone"}),
        %({"op":"set_id","target":{"a":"e2"},"new_id":"zone-a"}),
        %({"op":"set_id","target":{"id":"temp-zone"},"new_id":"zone-b"}),
        %({"op":"insert_shape","kind":"rect","new_id":"temp-zone","attrs":[]}),
        %({"op":"insert_shape","kind":"rect","new_id":"zone-a","attrs":[]}),
      ].map { |op| JSON.parse(op) }
      Llm::Ops.check(ops, rename_context).issues.keys.should eq ["op-5"]
    end

    it "does not release an id after a rejected rename" do
      rename_context = JSON.parse(%({"index":[{"a":"e1","id":"room-a","tag":"rect"},{"a":"e2","id":"room-b","tag":"rect"}]}))
      ops = [
        %({"op":"set_id","target":{"a":"e1"},"new_id":"room-b"}),
        %({"op":"insert_shape","kind":"rect","new_id":"room-a","attrs":[]}),
        %({"op":"set_id","target":{"a":"e1"},"new_id":null}),
        %({"op":"insert_shape","kind":"rect","new_id":"room-a","attrs":[]}),
      ].map { |op| JSON.parse(op) }
      Llm::Ops.check(ops, rename_context).issues.keys.should eq ["op-1", "op-2"]
    end

    it "flags everything past the op limit" do
      ops = Array.new(MAP_AI_MAX_OPS + 2) { JSON.parse(%({"op":"no_change","reason":"r","why":"w"})) }
      checked = Llm::Ops.check(ops, context)
      checked.ops.size.should eq MAP_AI_MAX_OPS + 2
      checked.issues["op-#{MAP_AI_MAX_OPS}"]?.should be_nil
      checked.issues["op-#{MAP_AI_MAX_OPS + 1}"].should contain "over the limit"
      checked.issues["op-#{MAP_AI_MAX_OPS + 2}"].should contain "over the limit"
    end

    it "keeps an op that is not an object, flagged" do
      checked = Llm::Ops.check([JSON.parse("5"), JSON.parse(%({"op":"ask","question":"?","why":"w"}))], context)
      checked.ops.size.should eq 2
      checked.issues.should eq({"op-1" => "not an object"})
    end

    it "accepts a protected target but never a protected new id" do
      ops = [
        JSON.parse(%({"op":"delete","target":{"a":"e4","id":null,"h":null},"targets":null,"why":"w"})),
        JSON.parse(%({"op":"set_id","target":{"a":"e5","id":null,"h":null},"new_id":"area-1.02-status","why":"w"})),
      ]
      checked = Llm::Ops.check(ops, context)
      checked.issues["op-1"]?.should be_nil
      checked.issues["op-2"].should eq "area-1.02-status is already an id in the map"
    end
  end
end
