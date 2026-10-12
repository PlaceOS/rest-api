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
      text.should contain "e4 | table-01.004 | rect | cls-12 | \"Desk 01.004\" | 640 420 30 20 | e1 | bookable | protected | d4d4d4d4"
      text.should contain "e7 | - | path | cls-1 | - | 0 0 1725.26 4 | e1 | art | - | 07070707"
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
      kinds.index!("image").should be < kinds.index!(&.starts_with?("ANNOTATIONS"))
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
    it "renders the vocabulary in the strict dialect" do
      schema = Llm::Schema.openai

      schema["type"].as_s.should eq "object"
      schema["additionalProperties"].as_bool.should be_false
      schema["required"].as_a.map(&.as_s).should eq ["summary", "ops", "questions"]

      op = schema["properties"]["ops"]["items"]
      op["additionalProperties"].as_bool.should be_false
      op["required"].as_a.map(&.as_s).should eq op["properties"].as_h.keys
      op["properties"]["op"]["enum"].as_a.map(&.as_s).should eq Llm::Schema::OPS
      op["properties"]["why"]["type"].as_s.should eq "string"

      # optional fields are nullable, enums included
      op["properties"]["name"]["type"].as_a.map(&.as_s).should eq ["string", "null"]
      op["properties"]["kind"]["type"].as_a.map(&.as_s).should eq ["string", "null"]
      op["properties"]["kind"]["enum"].as_a.last.raw.should be_nil
      op["properties"]["kind"]["enum"].as_a.size.should eq Llm::Schema::SHAPES.size + 1

      target = op["properties"]["target"]
      target["type"].as_a.map(&.as_s).should eq ["object", "null"]
      target["required"].as_a.map(&.as_s).should eq ["a", "id", "h"]
      target["additionalProperties"].as_bool.should be_false

      op["properties"]["translate"]["minItems"].as_i.should eq 2
      op["properties"]["translate"]["items"]["type"].as_s.should eq "number"
      op["properties"]["attrs"]["items"]["required"].as_a.map(&.as_s).should eq ["name", "value"]

      # every object anywhere in the tree is closed and fully required
      PlaceOS::Api.assert_strict_objects(schema)
    end

    it "lists the fields each op reads" do
      Llm::Schema::FIELDS_BY_OP.keys.should eq Llm::Schema::OPS
      Llm::Schema.reference.should contain "duplicate: target, new_id, translate, count, id_pattern"
      Llm::Schema.valid_id?("table-01.018").should be_true
      Llm::Schema.valid_id?("1abc").should be_false
      Llm::Schema.valid_id?("ai desk").should be_false
      Llm::Schema.allowed_attribute?("data-name").should be_true
      Llm::Schema.allowed_attribute?("onclick").should be_false
      Llm::Schema.allowed_attribute?("href").should be_false
    end
  end

  describe Llm::Ops do
    context = JSON.parse(File.read(File.join(__DIR__, "fixtures/map_ai/context.json")))

    it "reads fenced JSON and refuses prose" do
      envelope = Llm::Ops.parse("```json\n{\"summary\":\"s\",\"ops\":[],\"questions\":[\"which?\"]}\n```")
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

    it "numbers the ops and flags the ones that fail a check, keeping them" do
      ops = [
        op(%({"op":"set_attr","target":{"a":"e2","id":"area-1.01-status","h":"b2b2b2b2"},"name":"fill","value":"#90ee90","why":"w"})),
        op(%({"op":"set_attr","target":{"a":"e99","id":null,"h":null},"name":"fill","value":"#90ee90","why":"w"})),
        op(%({"op":"set_attr","target":{"a":"e2","id":"table-01.004","h":null},"name":"fill","value":"#000","why":"w"})),
        op(%({"op":"set_attr","target":{"a":"e2","id":null,"h":"stale"},"name":"fill","value":"#000","why":"w"})),
        op(%({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"onclick","value":"x","why":"w"})),
        op(%({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"data-name","value":"Boardroom","why":"w"})),
        op(%({"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"visibility","value":"display:none","why":"w"})),
        op(%({"op":"set_text","target":{"a":"e2","id":null,"h":null},"text":"x","why":"w"})),
        op(%({"op":"set_text","target":{"a":"e6","id":null,"h":null},"text":"Boardroom","why":"w"})),
        op(%({"op":"transform","target":{"a":"e5","id":null,"h":null},"translate":[20,0],"why":"w"})),
        op(%({"op":"transform","targets":[{"a":"e4","id":null,"h":null},{"a":"e5","id":null,"h":null}],"translate":[20],"why":"w"})),
        op(%({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":"table-01.006","translate":[40,0],"count":2,"why":"w"})),
        op(%({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":"table-01.004","translate":[40,0],"why":"w"})),
        op(%({"op":"duplicate","target":{"a":"e5","id":null,"h":null},"new_id":"1bad","translate":[40,0],"why":"w"})),
        op(%({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"kind":"rect","attrs":[{"name":"x","value":"1"},{"name":"fill","value":"#fff"}],"new_id":"ai-desk-1","why":"w"})),
        op(%({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"kind":"script","attrs":[],"why":"w"})),
        op(%({"op":"insert_shape","parent":{"a":"e1","id":null,"h":null},"kind":"rect","attrs":[{"name":"onload","value":"x"}],"why":"w"})),
        op(%({"op":"set_style_rule","selector":".cls-12","declarations":"fill: #eee; stroke: #333","why":"w"})),
        op(%({"op":"set_style_rule","selector":"*","declarations":"fill: #eee","why":"w"})),
        op(%({"op":"set_style_rule","selector":".cls-12","declarations":"background: url(http://x)","why":"w"})),
        op(%({"op":"set_id","target":{"a":"e5","id":null,"h":null},"new_id":"table-01.005-renamed","why":"w"})),
        op(%({"op":"reorder","target":{"a":"e5","id":null,"h":null},"position":"last","why":"w"})),
        op(%({"op":"reorder","target":{"a":"e5","id":null,"h":null},"why":"w"})),
        op(%({"op":"group","targets":[{"a":"e4","id":null,"h":null},{"a":"e5","id":null,"h":null}],"new_id":"ai-desks","why":"w"})),
        op(%({"op":"ungroup","target":{"a":"e5","id":null,"h":null},"why":"w"})),
        op(%({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<path id=\\"area-1.01-status\\" class=\\"cls-3\\" d=\\"M0 0h1v1z\\"/>","why":"w"})),
        op(%({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<g><rect onload=\\"alert(1)\\"/></g>","why":"w"})),
        op(%({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<rect/><rect/>","why":"w"})),
        op(%({"op":"replace_element","target":{"a":"e2","id":null,"h":null},"markup":"<a href=\\"http://x\\"><rect/></a>","why":"w"})),
        op(%({"op":"replace_path","target":{"a":"e2","id":null,"h":null},"d":"M0 0 L10 10 Z","why":"w"})),
        op(%({"op":"replace_path","target":{"a":"e5","id":null,"h":null},"d":"M0 0","why":"w"})),
        op(%({"op":"no_change","reason":"nothing to do","why":"w"})),
        op(%({"op":"ask","question":"which room?","why":"w"})),
        op(%({"op":"ask","why":"w"})),
        op(%({"op":"explode","why":"w"})),
      ]

      checked = Llm::Ops.check(ops, context)
      checked.size.should eq ops.size
      checked.map(&.["id"].as_s).first(3).should eq ["op-1", "op-2", "op-3"]

      issues = checked.map { |entry| entry["server_issue"]?.try(&.as_s?) }
      issues[0].should be_nil
      issues[1].should eq "anchor e99 is not in the index"
      issues[2].should eq "anchor e2 and id table-01.004 are different elements"
      issues[3].to_s.should contain "hash mismatch"
      issues[4].should eq "attribute onclick may not be set"
      issues[5].should be_nil
      issues[6].to_s.should contain "visibility must be one of"
      issues[7].should eq "set_text only applies to text and tspan elements"
      issues[8].should be_nil
      issues[9].should be_nil
      issues[10].should eq "translate must be [dx, dy]"
      issues[11].should be_nil
      issues[12].should eq "table-01.004 is already an id in the map"
      issues[13].to_s.should contain "is not a valid id"
      issues[14].should be_nil
      issues[15].should eq "script is not a shape that can be inserted"
      issues[16].should eq "attribute onload may not be set on a new element"
      issues[17].should be_nil
      issues[18].should eq "the selector * is not allowed"
      issues[19].should eq "declarations may not import or reference URLs"
      issues[20].should be_nil
      issues[21].should be_nil
      issues[22].should eq "reorder needs exactly one of before, after or position"
      issues[23].should be_nil
      issues[24].should eq "ungroup only applies to a group"
      issues[25].should be_nil
      issues[26].should eq "event handler attributes are not allowed"
      issues[27].should eq "the markup must be exactly one element"
      issues[28].should eq "<a> is not allowed"
      issues[29].should be_nil
      issues[30].should eq "replace_path only applies to a path"
      issues[31].should be_nil
      issues[32].should be_nil
      issues[33].should eq "ask needs a question"
      issues[34].should eq %(unknown operation "explode")
    end

    it "flags everything past the op limit" do
      ops = Array.new(MAP_AI_MAX_OPS + 2) do
        op(%({"op":"no_change","reason":"r","why":"w"}))
      end
      checked = Llm::Ops.check(ops, context)
      checked[MAP_AI_MAX_OPS - 1]["server_issue"]?.should be_nil
      checked[MAP_AI_MAX_OPS]["server_issue"].as_s.should contain "over the limit"
      checked.last["server_issue"].as_s.should contain "over the limit"
    end

    it "accepts a protected target but never a protected new id" do
      ops = [
        op(%({"op":"delete","target":{"a":"e4","id":null,"h":null},"why":"w"})),
        op(%({"op":"set_id","target":{"a":"e5","id":null,"h":null},"new_id":"area-1.02-status","why":"w"})),
      ]
      checked = Llm::Ops.check(ops, context)
      checked[0]["server_issue"]?.should be_nil
      checked[1]["server_issue"].as_s.should eq "area-1.02-status is already an id in the map"
    end
  end
end
