require "../helper"

module PlaceOS::Api
  # A level zone under the org zone the auth helper points every authority at,
  # which is what the legacy ACL (concierge: manage) and the AI gate look at.
  def self.map_ai_level : Model::Zone
    zone = Model::Generator.zone
    zone.parent_id = Spec::Authentication.org_zone.id.as(String)
    zone.tags = Set{"level"}
    zone.map_id = "/api/engine/v2/uploads/upload-spec/url"
    zone.save!
  end

  def self.map_ai_context : JSON::Any
    JSON.parse(File.read(File.join(__DIR__, "../fixtures/map_ai/context.json")))
  end

  # the model's answer for the fixture context: one grounded recolour
  MAP_AI_ANSWER = {
    summary: "Recoloured Meeting 1.01 light green.",
    ops:     [
      {
        op:     "set_attr",
        why:    "Meeting 1.01 is the room the instruction names.",
        target: {a: "e2", id: "area-1.01-status", h: "b2b2b2b2"},
        name:   "fill",
        value:  "#90ee90",
      },
    ],
    questions: [] of String,
  }.to_json

  describe MapAI do
    base = MapAI.base_route

    before_each do
      Model::SignageAIJob.clear
      Model::SignageAIProvider.clear
      Model::Upload.clear
      Model::Storage.clear
      clear_group_tables

      WebMock.allow_net_connect = false
    end

    describe "capabilities" do
      it "is off, with a reason, when the domain has no provider" do
        result = client.get(File.join(base, "capabilities"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body)
        body["enabled"].as_bool.should be_false
        body["reason"].as_s.should eq "no AI provider is configured for this domain"
        body["providers"].as_a.should be_empty
        body["limits"]["max_context_bytes"].as_i.should eq MAP_AI_MAX_CONTEXT_BYTES
      end

      it "is off when the only provider is switched off" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        Model::Generator.signage_ai_provider(authority: authority, name: "off-#{random_name}", enabled: false).save!

        body = JSON.parse(client.get(File.join(base, "capabilities"), headers: Spec::Authentication.headers).body)
        body["enabled"].as_bool.should be_false
      end

      it "is off when the only provider cannot edit maps yet" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        Model::Generator.signage_ai_provider(
          authority: authority,
          name: "vertex-#{random_name}",
          provider: Model::SignageAIProvider::Provider::GOOGLE_VERTEX,
          credentials: %({"project_id":"p","client_email":"e","private_key":"k"}),
        ).save!

        body = JSON.parse(client.get(File.join(base, "capabilities"), headers: Spec::Authentication.headers).body)
        body["enabled"].as_bool.should be_false
        body["reason"].as_s.should eq "the configured AI provider cannot edit maps yet"
      end

      it "is on, with the text model and what is left of the map quota" do
        _, _, provider = setup_signage_ai(quotas: {"map_user_per_day" => JSON::Any.new(5_i64), "user_per_day" => JSON::Any.new(1_i64)})
        provider.text_model = "gpt-5.4-mini-custom"
        provider.save!
        user, headers = Spec::Authentication.authentication

        # image jobs do not count against the map quota, map jobs do
        Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 2).save!
        Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit).save!

        result = client.get(File.join(base, "capabilities"), headers: headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body)
        body["enabled"].as_bool.should be_true
        body["default_provider_id"].as_s.should eq provider.id.to_s
        body["quota"]["user_remaining_today"].as_i.should eq 4
        body["limits"]["max_ops"].as_i.should eq MAP_AI_MAX_OPS

        providers = body["providers"].as_a
        providers.size.should eq 1
        providers.first["provider"].as_s.should eq "OPENAI"
        providers.first["text_model"].as_s.should eq "gpt-5.4-mini-custom"
      end

      it "falls back to the default text model" do
        setup_signage_ai
        body = JSON.parse(client.get(File.join(base, "capabilities"), headers: Spec::Authentication.headers).body)
        body["providers"].as_a.first["text_model"].as_s.should eq MAP_AI_DEFAULT_OPENAI_MODEL
      end

      it "lists the text models each provider can run, the row's own first" do
        authority, _, provider = setup_signage_ai
        provider.text_model = "gpt-5.4-mini-custom"
        provider.save!
        Model::Generator.signage_ai_provider(
          authority: authority,
          name: "claude-#{random_name}",
          provider: Model::SignageAIProvider::Provider::ANTHROPIC,
        ).save!

        body = JSON.parse(client.get(File.join(base, "capabilities"), headers: Spec::Authentication.headers).body)
        body["enabled"].as_bool.should be_true
        body["default_provider_id"].as_s.should eq provider.id.to_s
        providers = body["providers"].as_a
        providers.size.should eq 2

        openai = providers.find! { |entry| entry["provider"].as_s == "OPENAI" }
        openai["text_model"].as_s.should eq "gpt-5.4-mini-custom"
        openai["text_models"].as_a.map(&.as_s).should eq ["gpt-5.4-mini-custom"] + MAP_AI_OPENAI_MODELS

        claude = providers.find! { |entry| entry["provider"].as_s == "ANTHROPIC" }
        claude["text_model"].as_s.should eq MAP_AI_DEFAULT_ANTHROPIC_MODEL
        claude["text_models"].as_a.map(&.as_s).should eq MAP_AI_ANTHROPIC_MODELS
        claude["text_models"].as_a.map(&.as_s).should contain "claude-fable-5-1"
      end
    end

    describe "edit" do
      it "accepts the request, records the context, and finishes the job with the ops" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        level = map_ai_level
        requests = [] of JSON::Any

        HttpMocks.map_ai_vendor(MAP_AI_ANSWER, requests: requests)
        HttpMocks.signage_ai_vendor

        context = map_ai_context
        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {zone_id: level.id, instruction: "Make meeting room 1.01 light green.", context: context}.to_json,
        )

        result.status_code.should eq 202
        accepted = JSON.parse(result.body)
        accepted["state"].as_s.should eq "queued"
        accepted["kind"].as_s.should eq "map_edit"
        accepted["zone_id"].as_s.should eq level.id
        accepted["provider"].as_s.should eq "OPENAI"
        accepted["model"].as_s.should eq MAP_AI_DEFAULT_OPENAI_MODEL
        accepted["instruction"].as_s.should eq "Make meeting room 1.01 light green."
        accepted["ops"].as_a.should be_empty

        job_id = accepted["id"].as_s
        stored = Model::SignageAIJob.find!(UUID.new(job_id))
        stored.kind.should eq Model::SignageAIJob::Kind::MapEdit
        stored.candidates.should eq 1
        stored.provider_id.should eq provider.id
        stored.user_id.should eq user.id
        stored.request["context_bytes"].as_i.should eq context.to_json.bytesize
        stored.request["context_sha256"].as_s.size.should eq 64
        stored.request["element_count"].as_i.should eq 7
        # the context body itself is not on the row
        stored.request.to_json.should_not contain "table-01.004"

        final = await_signage_ai_job(base, job_id, headers)
        Llm.slots.available.should eq MAP_AI_MAX_CALLS
        final["state"].as_s.should eq "done"
        final["summary"].as_s.should eq "Recoloured Meeting 1.01 light green."
        final["schema_version"].as_i.should eq 1
        final["questions"].as_a.should be_empty
        final["usage"]["total_tokens"].as_i.should eq 1280
        final["usage"]["model"].as_s.should eq MAP_AI_DEFAULT_OPENAI_MODEL
        final["cost_units"].as_f.should eq 1280.0
        final["error_kind"]?.should be_nil

        ops = final["ops"].as_a
        ops.size.should eq 1
        # the model's op with nothing added (jsonb orders the keys); the editor
        # validates it against the same schema
        ops.first.as_h.keys.sort!.should eq ["name", "op", "target", "value", "why"]
        ops.first["target"]["a"].as_s.should eq "e2"
        ops.first["value"].as_s.should eq "#90ee90"
        final["server_issues"].as_h.should be_empty
        final["usage"]["attempts"].as_i.should eq 1

        # what reached the vendor
        requests.size.should eq 1
        sent = requests.first
        sent["model"].as_s.should eq MAP_AI_DEFAULT_OPENAI_MODEL
        sent["max_completion_tokens"].as_i.should eq MAP_AI_MAX_OUTPUT_TOKENS
        sent["reasoning_effort"].as_s.should eq "low"
        sent["response_format"]["type"].as_s.should eq "json_schema"
        sent["response_format"]["json_schema"]["strict"].as_bool.should be_true
        sent["response_format"]["json_schema"]["name"].as_s.should eq "map_edit"
        sent["response_format"]["json_schema"]["schema"].should eq Llm::Schema.openai
        messages = sent["messages"].as_a
        messages.first["role"].as_s.should eq "system"
        messages.first["content"].as_s.should contain "You edit SVG floor-plan maps"
        user_parts = messages.last["content"].as_a
        user_parts.first["type"].as_s.should eq "text"
        user_parts.first["text"].as_s.should contain "e2 | area-1.01-status"
        user_parts.last["text"].as_s.should end_with "INSTRUCTION\nMake meeting room 1.01 light green."
        sent["temperature"]?.should be_nil

        Model::SignageAIJob.sum_candidates(user.id.as(String), 1.day.ago, Model::SignageAIJob::Kind::MapEdit).should eq 1
      end

      it "sends the markup snapshot as an image part and tags it for the sweep" do
        _, storage, _ = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        level = map_ai_level
        requests = [] of JSON::Any

        snapshot = Model::Generator.upload(uploader: user, storage_id: storage.id)
        snapshot.file_name = "snapshot.png"
        snapshot.save!

        HttpMocks.map_ai_vendor(MAP_AI_ANSWER, requests: requests)
        HttpMocks.signage_ai_storage

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {zone_id: level.id, instruction: "Recolour the room under pin 2.", context: map_ai_context, markup_upload_id: snapshot.id}.to_json,
        )
        result.status_code.should eq 202
        job_id = JSON.parse(result.body)["id"].as_s
        JSON.parse(result.body)["markup_upload_id"].as_s.should eq snapshot.id

        Model::Upload.find!(snapshot.id.as(String)).tags.should eq [ImageGen::Store::MARKUP_TAG]
        Model::SignageAIJob.find!(UUID.new(job_id)).upload_ids.should eq [snapshot.id]

        final = await_signage_ai_job(base, job_id, headers)
        final["state"].as_s.should eq "done"

        parts = requests.first["messages"].as_a.last["content"].as_a
        image = parts.find! { |part| part["type"].as_s == "image_url" }
        image["image_url"]["url"].as_s.should start_with "data:image/jpeg;base64,"
        image["image_url"]["detail"].as_s.should eq "high"
        # subtrees before the image, annotations after it
        parts.index!(image).should be > parts.index! { |part| part["type"].as_s == "text" && part["text"].as_s.starts_with?("SUBTREES") }
        parts.index!(image).should be < parts.index! { |part| part["type"].as_s == "text" && part["text"].as_s.starts_with?("ANNOTATIONS") }
      end

      it "refuses a snapshot the caller does not own" do
        authority, storage, _ = setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level

        owner = Model::Generator.user(authority: authority).save!
        snapshot = Model::Generator.upload(uploader: owner, storage_id: storage.id)
        snapshot.file_name = "snapshot.png"
        snapshot.save!

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {zone_id: level.id, instruction: "x", context: map_ai_context, markup_upload_id: snapshot.id}.to_json,
        )
        result.status_code.should eq 403
        JSON.parse(result.body)["kind"].as_s.should eq "permission"
      end

      it "accepts fenced JSON" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level

        HttpMocks.map_ai_vendor("```json\n#{MAP_AI_ANSWER}\n```")

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 202

        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "done"
        final["ops"].as_a.size.should eq 1
      end

      it "fails the job as invalid_response when the model answers in prose" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level

        HttpMocks.map_ai_vendor_garbage

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 202

        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "failed"
        final["error_kind"].as_s.should eq "invalid_response"
        final["error_message"].as_s.should eq "the model did not answer with JSON"
        # a failed call still spent tokens
        final["cost_units"].as_f.should eq 1280.0
      end

      it "retries once at a larger output budget, then fails as invalid_response when still cut off" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level
        requests = [] of JSON::Any

        HttpMocks.map_ai_vendor(%({"summary":"partial","ops":[{"op":"set_attr"), finish: "length", requests: requests)

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "failed"
        final["error_kind"].as_s.should eq "invalid_response"
        final["error_message"].as_s.should contain "cut off"
        # both attempts were billed
        final["cost_units"].as_f.should eq 2560.0

        requests.size.should eq 2
        requests[0]["max_completion_tokens"].as_i.should eq MAP_AI_MAX_OUTPUT_TOKENS
        requests[1]["max_completion_tokens"].as_i.should eq MAP_AI_RETRY_OUTPUT_TOKENS
      end

      it "finishes with the second attempt when the first was cut off" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level
        requests = [] of JSON::Any

        HttpMocks.map_ai_vendor_cut_off(MAP_AI_ANSWER, requests)

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "done"
        final["ops"].as_a.size.should eq 1
        final["usage"]["attempts"].as_i.should eq 2
        final["usage"]["total_tokens"].as_i.should eq 2560
        final["usage"]["finish"].as_s.should eq "stop"
        final["cost_units"].as_f.should eq 2560.0

        requests.size.should eq 2
        requests[1]["max_completion_tokens"].as_i.should eq MAP_AI_RETRY_OUTPUT_TOKENS
      end

      it "keeps an op with an unknown anchor, flagged rather than dropped" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level

        answer = {
          summary: "s",
          ops:     [
            {op: "set_attr", why: "w", target: {a: "e404", id: nil, h: nil}, name: "fill", value: "#fff"},
            {op: "set_attr", why: "w", target: {a: "e5", id: nil, h: nil}, name: "fill", value: "#fff"},
          ],
          questions: [] of String,
        }.to_json
        HttpMocks.map_ai_vendor(answer)

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "done"

        ops = final["ops"].as_a
        ops.size.should eq 2
        ops[0].as_h.has_key?("server_issue").should be_false
        final["server_issues"].as_h.keys.should eq ["op-1"]
        final["server_issues"]["op-1"].as_s.should eq "anchor e404 is not in the index"
      end

      it "records a refusal as a moderation failure" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level

        HttpMocks.map_ai_vendor_refused

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "failed"
        final["error_kind"].as_s.should eq "moderation"
        final["error_message"].as_s.should eq "I can't help with that."
      end

      it "records a vendor that never answers as a timeout" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level

        HttpMocks.map_ai_vendor_timeout

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "failed"
        final["error_kind"].as_s.should eq "timeout"
      end

      it "drops reasoning_effort when the model rejects it" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level
        requests = [] of JSON::Any

        HttpMocks.map_ai_vendor_no_reasoning(MAP_AI_ANSWER, requests)

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "done"

        requests.size.should eq 2
        requests[0]["reasoning_effort"].as_s.should eq "low"
        requests[1]["reasoning_effort"]?.should be_nil
      end

      it "edits through an Anthropic provider with the model the editor chose" do
        authority, _, _ = setup_signage_ai
        claude = Model::Generator.signage_ai_provider(
          authority: authority,
          name: "claude-#{random_name}",
          provider: Model::SignageAIProvider::Provider::ANTHROPIC,
        ).save!
        claude.credentials_json = {"api_key" => JSON::Any.new("test-key"), "workspace_id" => JSON::Any.new("wrkspc_test")}
        claude.save!
        _, headers = Spec::Authentication.authentication
        level = map_ai_level
        requests = [] of JSON::Any
        seen = [] of HTTP::Headers

        HttpMocks.map_ai_anthropic(MAP_AI_ANSWER, requests: requests, headers: seen)
        HttpMocks.signage_ai_vendor

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {
            zone_id:     level.id,
            instruction: "Make meeting room 1.01 light green.",
            context:     map_ai_context,
            provider_id: claude.id.to_s,
            model:       "claude-fable-5-1",
          }.to_json,
        )
        result.status_code.should eq 202
        accepted = JSON.parse(result.body)
        accepted["provider"].as_s.should eq "ANTHROPIC"
        accepted["model"].as_s.should eq "claude-fable-5-1"

        final = await_signage_ai_job(base, accepted["id"].as_s, headers)
        final["state"].as_s.should eq "done"
        final["summary"].as_s.should eq "Recoloured Meeting 1.01 light green."
        final["ops"].as_a.size.should eq 1
        final["usage"]["model"].as_s.should eq "claude-fable-5-1"
        final["usage"]["served_by"].as_s.should eq "claude-fable-5-1"
        final["usage"]["total_tokens"].as_i.should eq 1590
        final["cost_units"].as_f.should eq 1590.0

        requests.size.should eq 1
        sent = requests.first
        sent["model"].as_s.should eq "claude-fable-5-1"
        sent["max_tokens"].as_i.should eq MAP_AI_MAX_OUTPUT_TOKENS
        sent["system"].as_s.should contain "You edit SVG floor-plan maps"
        sent["output_config"]["format"]?.should be_nil
        sent["tools"][0]["name"].as_s.should eq "map_edit"
        sent["tools"][0]["input_schema"].should eq Llm::Schema.openai
        sent["tools"][0]["strict"]?.should be_nil
        sent["tool_choice"]["type"].as_s.should eq "auto"
        sent["tool_choice"]["disable_parallel_tool_use"].as_bool.should be_true
        sent["output_config"]["effort"].as_s.should eq MAP_AI_ANTHROPIC_EFFORT
        sent["fallbacks"].as_s.should eq "default"
        sent["thinking"]?.should be_nil
        sent["temperature"]?.should be_nil
        sent["response_format"]?.should be_nil
        messages = sent["messages"].as_a
        messages.size.should eq 1
        messages.first["role"].as_s.should eq "user"
        parts = messages.first["content"].as_a
        parts.first["type"].as_s.should eq "text"
        parts.first["text"].as_s.should contain "e2 | area-1.01-status"
        parts.last["text"].as_s.should end_with "INSTRUCTION\nMake meeting room 1.01 light green."

        seen.size.should eq 1
        seen.first["x-api-key"].should eq "test-key"
        seen.first["anthropic-workspace-id"].should eq "wrkspc_test"
        seen.first["anthropic-version"].should eq "2023-06-01"
        seen.first["anthropic-beta"].should eq "server-side-fallback-2026-07-01"
        seen.first["Authorization"]?.should be_nil
      end

      it "sends no fallbacks to a model that takes none, and drops them when one rejects them" do
        authority, _, _ = setup_signage_ai
        claude = Model::Generator.signage_ai_provider(
          authority: authority,
          name: "claude-#{random_name}",
          provider: Model::SignageAIProvider::Provider::ANTHROPIC,
        ).save!
        _, headers = Spec::Authentication.authentication
        level = map_ai_level
        requests = [] of JSON::Any
        seen = [] of HTTP::Headers

        HttpMocks.map_ai_anthropic(MAP_AI_ANSWER, requests: requests, headers: seen)
        HttpMocks.signage_ai_vendor

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {zone_id: level.id, instruction: "x", context: map_ai_context, provider_id: claude.id.to_s, model: "claude-haiku-5-5"}.to_json,
        )
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "done"
        requests.size.should eq 1
        requests.first["fallbacks"]?.should be_nil
        seen.first["anthropic-beta"]?.should be_nil
        seen.first["anthropic-workspace-id"]?.should be_nil

        requests.clear
        WebMock.reset
        HttpMocks.map_ai_anthropic_no_fallbacks(MAP_AI_ANSWER, requests)
        HttpMocks.signage_ai_vendor

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {zone_id: level.id, instruction: "x", context: map_ai_context, provider_id: claude.id.to_s, model: "claude-opus-5-5"}.to_json,
        )
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "done"
        requests.size.should eq 2
        requests.first["fallbacks"].as_s.should eq "default"
        requests.last["fallbacks"]?.should be_nil
        final["usage"]["attempts"].as_i.should eq 1
      end

      it "records an Anthropic refusal as a moderation failure" do
        authority, _, _ = setup_signage_ai
        claude = Model::Generator.signage_ai_provider(
          authority: authority,
          name: "claude-#{random_name}",
          provider: Model::SignageAIProvider::Provider::ANTHROPIC,
        ).save!
        _, headers = Spec::Authentication.authentication
        level = map_ai_level

        HttpMocks.map_ai_anthropic_refused
        HttpMocks.signage_ai_vendor

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {zone_id: level.id, instruction: "x", context: map_ai_context, provider_id: claude.id.to_s}.to_json,
        )
        result.status_code.should eq 202
        JSON.parse(result.body)["model"].as_s.should eq MAP_AI_DEFAULT_ANTHROPIC_MODEL
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "failed"
        final["error_kind"].as_s.should eq "moderation"
        final["error_message"].as_s.should eq "This request was declined."
      end

      it "answers 429 by the map quota, not the image quota" do
        _, _, provider = setup_signage_ai(quotas: {"map_user_per_day" => JSON::Any.new(1_i64), "user_per_day" => JSON::Any.new(60_i64)})
        user, headers = Spec::Authentication.authentication
        level = map_ai_level

        Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit).save!

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 429
        JSON.parse(result.body)["kind"].as_s.should eq "quota"
      end

      it "does not count image jobs against the map quota" do
        _, _, provider = setup_signage_ai(quotas: {"map_user_per_day" => JSON::Any.new(1_i64), "user_per_day" => JSON::Any.new(1_i64)})
        user, headers = Spec::Authentication.authentication
        level = map_ai_level
        Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 4).save!

        HttpMocks.map_ai_vendor(MAP_AI_ANSWER)

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 202
        await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
      end

      it "refuses a write with a read-only scope" do
        setup_signage_ai
        level = map_ai_level
        _, scoped_headers = Spec::Authentication.authentication(scope: [Model::UserJWT::Scope.new("map_ai", :read)])

        result = client.post(File.join(base, "edit"), headers: scoped_headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 403
      end

      it "lets a concierge user with manage on the org zone edit" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false, groups: ["concierge"])
        level = map_ai_level

        HttpMocks.map_ai_vendor(MAP_AI_ANSWER)

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 202
        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "done"
      end

      it "refuses a caller who cannot update the zone" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        level = map_ai_level

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 403
        Model::SignageAIJob.count.should eq 0
      end

      # Any signage group with Update may PATCH any zone today; the AI gate
      # does not inherit that grant.
      it "refuses the broad signage grant" do
        authority, _, _ = setup_signage_ai
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        signage_group(authority, user, Model::Permissions::Read | Model::Permissions::Update)
        level = map_ai_level

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 403
      end

      it "hides a zone outside the caller's organisation" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false, groups: ["concierge"])

        other_org = Model::Generator.zone
        other_org.tags = Set{"org"}
        other_org.save!
        level = Model::Generator.zone
        level.parent_id = other_org.id
        level.save!

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context}.to_json)
        result.status_code.should eq 404

        missing = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: "zone-does-not-exist", instruction: "x", context: map_ai_context}.to_json)
        missing.status_code.should eq 404
      end

      it "refuses a context over the cap, or of the wrong shape" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication
        level = map_ai_level

        huge = map_ai_context
        huge.as_h["subtrees"] = JSON::Any.new({"e2" => JSON::Any.new("x" * (MAP_AI_MAX_CONTEXT_BYTES + 1))})
        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: huge}.to_json)
        result.status_code.should eq 422

        wrong = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: {schema: "something/else", index: [] of String}}.to_json)
        wrong.status_code.should eq 422

        none = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x"}.to_json)
        none.status_code.should eq 422

        blank = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "   ", context: map_ai_context}.to_json)
        blank.status_code.should eq 422

        Model::SignageAIJob.count.should eq 0
      end

      it "replays an accepted submission rather than spending again" do
        setup_signage_ai
        user, headers = Spec::Authentication.authentication
        level = map_ai_level

        HttpMocks.map_ai_vendor(MAP_AI_ANSWER)

        body = {zone_id: level.id, instruction: "x", context: map_ai_context, idempotency_key: "map-#{random_name}"}.to_json
        first = client.post(File.join(base, "edit"), headers: headers, body: body)
        first.status_code.should eq 202
        job_id = JSON.parse(first.body)["id"].as_s

        second = client.post(File.join(base, "edit"), headers: headers, body: body)
        second.status_code.should eq 202
        JSON.parse(second.body)["id"].as_s.should eq job_id

        Model::SignageAIJob.where(user_id: user.id.as(String)).to_a.size.should eq 1
        await_signage_ai_job(base, job_id, headers)
      end

      it "answers 409 when the idempotency key belongs to an image job" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        level = map_ai_level
        image_job = Model::Generator.signage_ai_job(user: user, provider: provider)
        image_job.idempotency_key = "shared-#{random_name}"
        image_job.save!

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {zone_id: level.id, instruction: "x", context: map_ai_context, idempotency_key: image_job.idempotency_key}.to_json,
        )
        result.status_code.should eq 409
        Model::SignageAIJob.where(user_id: user.id.as(String)).to_a.size.should eq 1
      end

      it "feeds the parent chain into the prompt" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        level = map_ai_level
        requests = [] of JSON::Any

        parent = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit)
        parent.state = Model::SignageAIJob::State::Done
        parent.result = JSON.parse(%({"summary":"Recoloured it.","ops":[{"op":"set_attr","target":{"a":"e2","id":null,"h":null},"name":"fill","value":"#90ee90","why":"w"}],"server_issues":{},"questions":[],"resolution":{"decision":"rejected","accepted_op_ids":[],"rejected_op_ids":["op-1"],"reasons":["too bright"]}}))
        parent.save!

        HttpMocks.map_ai_vendor(MAP_AI_ANSWER, requests: requests)

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {zone_id: level.id, instruction: "Paler.", context: map_ai_context, parent_job_id: parent.id}.to_json,
        )
        result.status_code.should eq 202
        JSON.parse(result.body)["parent_job_id"].as_s.should eq parent.id.to_s
        await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)

        text = requests.first["messages"].as_a.last["content"].as_a.map(&.["text"].as_s).join("\n")
        text.should contain "Turn 1 instruction: recolour the boardroom light blue"
        text.should contain "Turn 1 outcome: rejected; rejected: op-1; reasons: too bright"
        text.index!("Turn 1 instruction").should be < text.index!("INSTRUCTION\nPaler.")
      end

      it "refuses an image job or another domain's job as a parent" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        level = map_ai_level
        image_job = Model::Generator.signage_ai_job(user: user, provider: provider).save!

        result = client.post(File.join(base, "edit"), headers: headers, body: {zone_id: level.id, instruction: "x", context: map_ai_context, parent_job_id: image_job.id}.to_json)
        result.status_code.should eq 404
        # nothing was written and no slot is held
        Model::SignageAIJob.where("kind = ?", "MAP_EDIT").to_a.should be_empty
        Llm.slots.available.should eq MAP_AI_MAX_CALLS
      end
    end

    describe "jobs" do
      it "lists only map edit jobs, by zone, and hides them from the signage list" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication

        image_job = Model::Generator.signage_ai_job(user: user, provider: provider).save!
        here = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit)
        here.request = JSON.parse(%({"zone_id":"zone-here"}))
        here.save!
        elsewhere = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit)
        elsewhere.request = JSON.parse(%({"zone_id":"zone-elsewhere"}))
        elsewhere.save!

        result = client.get(File.join(base, "jobs"), headers: headers)
        result.status_code.should eq 200
        ids = JSON.parse(result.body).as_a.map(&.["id"].as_s)
        ids.should contain here.id.to_s
        ids.should contain elsewhere.id.to_s
        ids.should_not contain image_job.id.to_s

        by_zone = JSON.parse(client.get(File.join(base, "jobs") + "?zone_id=zone-here", headers: headers).body).as_a
        by_zone.map(&.["id"].as_s).should eq [here.id.to_s]
        by_zone.first["zone_id"].as_s.should eq "zone-here"

        signage = JSON.parse(client.get(File.join(SignageAI.base_route, "jobs"), headers: headers).body).as_a.map(&.["id"].as_s)
        signage.should contain image_job.id.to_s
        signage.should_not contain here.id.to_s

        signage_maps = JSON.parse(client.get(File.join(SignageAI.base_route, "jobs") + "?kind=map_edit", headers: headers).body).as_a.map(&.["id"].as_s)
        signage_maps.should contain here.id.to_s
        signage_maps.should_not contain image_job.id.to_s

        client.get(File.join(base, "jobs") + "?kind=nope", headers: headers).status_code.should eq 422
      end

      it "answers 404 for an image job on the map routes" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        image_job = Model::Generator.signage_ai_job(user: user, provider: provider).save!

        client.get(File.join(base, "jobs", image_job.id.to_s), headers: headers).status_code.should eq 404
      end

      it "long polls and cancels like signage" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        job = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit).save!
        job_id = job.id.as(UUID)

        spawn do
          sleep 700.milliseconds
          Model::SignageAIJob.bump_version(job_id)
        end

        started = Time.utc
        result = client.get(File.join(base, "jobs", job_id.to_s) + "?wait=20&since=#{job.version}", headers: headers)
        (Time.utc - started).should be < 10.seconds
        result.status_code.should eq 200
        JSON.parse(result.body)["version"].as_i.should eq job.version + 1

        cancelled = client.post(File.join(base, "jobs", job_id.to_s, "cancel"), headers: headers)
        cancelled.status_code.should eq 200
        Model::SignageAIJob.find!(job_id).cancel_requested.should be_true
      end
    end

    describe "resolve" do
      it "records what the person did with the answer" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        job = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit)
        job.state = Model::SignageAIJob::State::Done
        job.result = JSON.parse(%({"schema_version":1,"summary":"s","ops":[{"op":"no_change","reason":"r","why":"w"}],"server_issues":{},"questions":[]}))
        job.save!

        result = client.post(
          File.join(base, "jobs", job.id.to_s, "resolve"),
          headers: headers,
          body: {decision: "partial", accepted_op_ids: ["op-1"], rejected_op_ids: ["op-2"], reasons: {"op-2" => "wrong room"}, saved_upload_id: "upload-123"}.to_json,
        )
        result.status_code.should eq 200

        body = JSON.parse(result.body)
        body["version"].as_i.should eq job.version + 1
        resolution = body["resolution"]
        resolution["decision"].as_s.should eq "partial"
        resolution["accepted_op_ids"].as_a.map(&.as_s).should eq ["op-1"]
        resolution["reasons"]["op-2"].as_s.should eq "wrong room"
        resolution["saved_upload_id"].as_s.should eq "upload-123"
        resolution["resolved_by"].as_s.should eq user.id
        # the ops are untouched
        body["ops"].as_a.size.should eq 1

        stored = Model::SignageAIJob.find!(job.id.as(UUID))
        stored.result["resolution"]["decision"].as_s.should eq "partial"

        bad = client.post(File.join(base, "jobs", job.id.to_s, "resolve"), headers: headers, body: {decision: "meh"}.to_json)
        bad.status_code.should eq 422
      end

      it "refuses somebody else's job, and a job still running" do
        authority, _, provider = setup_signage_ai
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        someone_else = Model::Generator.user(authority: authority).save!
        theirs = Model::Generator.signage_ai_job(user: someone_else, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit, state: Model::SignageAIJob::State::Done).save!
        client.post(File.join(base, "jobs", theirs.id.to_s, "resolve"), headers: headers, body: {decision: "applied"}.to_json).status_code.should eq 403

        user, own_headers = Spec::Authentication.authentication
        running = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit, state: Model::SignageAIJob::State::Running).save!
        client.post(File.join(base, "jobs", running.id.to_s, "resolve"), headers: own_headers, body: {decision: "applied"}.to_json).status_code.should eq 422
      end
    end

    describe "usage" do
      it "sums map edit spend only, for support" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication

        image_job = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 2)
        image_job.cost_units = 10.0
        image_job.save!
        map_job = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1, kind: Model::SignageAIJob::Kind::MapEdit)
        map_job.cost_units = 1280.0
        map_job.save!

        result = client.get(File.join(base, "usage"), headers: headers)
        result.status_code.should eq 200
        rows = Array(Model::SignageAIJob::UsageRow).from_json(result.body)
        rows.size.should eq 1
        rows.first.kind.should eq "map_edit"
        rows.first.cost_units.should eq 1280.0
        rows.first.candidates.should eq 1

        # the signage usage report now carries the kind as well
        signage_rows = Array(Model::SignageAIJob::UsageRow).from_json(client.get(File.join(SignageAI.base_route, "usage"), headers: headers).body)
        signage_rows.map(&.kind).sort!.should eq ["generate", "map_edit"]

        _, regular = Spec::Authentication.authentication(sys_admin: false, support: false)
        client.get(File.join(base, "usage"), headers: regular).status_code.should eq 403
      end
    end
  end
end
