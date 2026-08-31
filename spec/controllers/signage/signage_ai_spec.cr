require "../../helper"

module PlaceOS::Api
  # Everything a signage AI request needs: somewhere to put the image, and a
  # vendor to ask for one. Returns (authority, storage, provider).
  def self.setup_signage_ai(quotas : Hash(String, JSON::Any) = {} of String => JSON::Any)
    authority = Model::Authority.find_by_domain("localhost").not_nil!
    storage = Model::Generator.storage(authority_id: authority.id.as(String)).save!
    provider = Model::Generator.signage_ai_provider(
      authority: authority,
      name: "openai-#{random_name}",
      is_default: true,
      quotas: quotas,
    ).save!

    {authority, storage, provider}
  end

  # A signage group the caller may act in, hung off the authority root (an
  # authority only ever has one root group).
  def self.signage_group(authority, user, permissions : Model::Permissions)
    root = Model::Generator.group(authority: authority).save!
    group = Model::Generator.group(authority: authority, parent: root, subsystems: ["signage"]).save!
    Model::Generator.group_user(user: user, group: group, permissions: permissions).save!
    group
  end

  # Drive the long poll at `wait=0` until the job stops moving. The runner is a
  # fiber in this same process, so each poll gives it a turn.
  def self.await_signage_ai_job(base : String, id : String, headers : HTTP::Headers) : JSON::Any
    path = File.join(base, "jobs", id)

    100.times do
      response = client.get(path, headers: headers)
      response.status_code.should eq 200
      body = JSON.parse(response.body)
      return body if {"done", "failed", "cancelled"}.includes?(body["state"].as_s)
      sleep 100.milliseconds
    end

    raise "signage AI job #{id} never reached a final state"
  end

  describe SignageAI do
    base = SignageAI.base_route

    # `Spec.before_each` registers against the root context and would run for
    # every example in the suite. This hook has to stay local, because turning
    # live connections off suite wide would break the specs that talk to core.
    before_each do
      Model::SignageAIJob.clear
      Model::SignageAIProvider.clear
      Model::Playlist::Item.clear
      Model::Upload.clear
      Model::Storage.clear
      clear_group_tables

      # an unstubbed vendor or bucket call should fail loudly rather than reach
      # the internet: `HttpMocks.reset` allows real connections by default
      WebMock.allow_net_connect = false
    end

    describe "capabilities" do
      it "is off, with a reason, when the domain has no provider" do
        authority = Model::Authority.find_by_domain("localhost").not_nil!
        Model::Generator.storage(authority_id: authority.id.as(String)).save!

        result = client.get(File.join(base, "capabilities"), headers: Spec::Authentication.headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body)
        body["enabled"].as_bool.should be_false
        body["reason"].as_s.should eq "no AI provider is configured for this domain"
        body["providers"].as_a.should be_empty
      end

      it "is on, and reports what is left of the quota" do
        _, _, provider = setup_signage_ai(quotas: {"user_per_day" => JSON::Any.new(5_i64)})
        user, headers = Spec::Authentication.authentication

        # two candidates already spent today
        Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 2).save!

        result = client.get(File.join(base, "capabilities"), headers: headers)
        result.status_code.should eq 200

        body = JSON.parse(result.body)
        body["enabled"].as_bool.should be_true
        body["default_provider_id"].as_s.should eq provider.id.to_s
        body["aspect_ratios"].as_a.map(&.as_s).should contain "16:9"
        body["quota"]["user_remaining_today"].as_i.should eq 3

        providers = body["providers"].as_a
        providers.size.should eq 1
        providers.first["provider"].as_s.should eq "OPENAI"
        providers.first["models"].as_a.map(&.["id"].as_s).should contain "gpt-image-2"
      end
    end

    describe "generate" do
      it "accepts the request, stores the candidate and finishes the job" do
        _, storage, _ = setup_signage_ai
        user, headers = Spec::Authentication.authentication

        HttpMocks.signage_ai_vendor
        HttpMocks.signage_ai_storage

        result = client.post(
          File.join(base, "generate"),
          headers: headers,
          body: {prompt: "a poster for the office party", candidates: 1}.to_json,
        )

        result.status_code.should eq 202
        accepted = JSON.parse(result.body)
        accepted["state"].as_s.should eq "queued"
        accepted["kind"].as_s.should eq "generate"
        accepted["provider"].as_s.should eq "OPENAI"
        accepted["model"].as_s.should eq "gpt-image-2"

        job_id = accepted["id"].as_s
        Model::SignageAIJob.find!(UUID.new(job_id)).candidates.should eq 1

        final = await_signage_ai_job(base, job_id, headers)
        final["state"].as_s.should eq "done"
        final["images_produced"].as_i.should eq 1

        image = final["images"].as_a.first
        image["state"].as_s.should eq "done"
        image["width"].as_i.should eq 1
        image["mime"].as_s.should eq "image/jpeg"

        upload = Model::Upload.find!(image["upload_id"].as_s)
        upload.uploaded_by.should eq user.id
        upload.upload_complete.should be_true
        upload.public.should be_false
        upload.storage_id.should eq storage.id
        upload.tags.should contain ImageGen::Store::CANDIDATE_TAG
        upload.tags.should contain "ai-job-#{job_id}"
      end

      it "replays an accepted submission rather than spending again" do
        setup_signage_ai
        user, headers = Spec::Authentication.authentication

        HttpMocks.signage_ai_vendor
        HttpMocks.signage_ai_storage

        body = {prompt: "a poster", candidates: 1, idempotency_key: "spec-#{random_name}"}.to_json

        first = client.post(File.join(base, "generate"), headers: headers, body: body)
        first.status_code.should eq 202
        job_id = JSON.parse(first.body)["id"].as_s

        second = client.post(File.join(base, "generate"), headers: headers, body: body)
        second.status_code.should eq 202
        JSON.parse(second.body)["id"].as_s.should eq job_id

        Model::SignageAIJob.where(user_id: user.id.as(String)).to_a.size.should eq 1

        # let the runner finish so it hands its slot back
        await_signage_ai_job(base, job_id, headers)
      end

      # The case a real customer is in. Every other non-support spec here proves
      # a refusal, so nothing ever proved the path a paying user actually takes,
      # and the browser was not sending group_id at all.
      it "lets a non-support caller with Create on a signage group generate" do
        authority, _, _ = setup_signage_ai
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        group = signage_group(authority, user, Model::Permissions::Read | Model::Permissions::Create)

        HttpMocks.signage_ai_vendor
        HttpMocks.signage_ai_storage

        result = client.post(
          File.join(base, "generate"),
          headers: headers,
          body: {prompt: "a poster", candidates: 1, group_id: group.id}.to_json,
        )

        result.status_code.should eq 202
        job_id = JSON.parse(result.body)["id"].as_s
        Model::SignageAIJob.find!(UUID.new(job_id)).user_id.should eq user.id

        final = await_signage_ai_job(base, job_id, headers)
        final["state"].as_s.should eq "done"
        final["images_produced"].as_i.should eq 1
      end

      # The logo is a domain asset nobody personally owns. Routing it through
      # the caller-ownership check dropped it from every edit made by a customer
      # while still advertising the toggle, so this pins the actual policy.
      it "sends the brand logo on an edit for a caller who does not own it" do
        authority, storage, _ = setup_signage_ai
        owner, _ = Spec::Authentication.authentication
        logo = Model::Generator.upload(uploader: owner, storage_id: storage.id)
        logo.file_name = "logo.png"
        logo.save!

        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        # the org zone the auth helper points every authority at; setting our
        # own would be undone by the next authentication call
        zone = Spec::Authentication.org_zone
        Model::Metadata.where(parent_id: zone.id.as(String), name: "signage_ai").each(&.destroy)
        Model::Metadata.new(
          parent_id: zone.id.as(String),
          name: "signage_ai",
          details: JSON.parse({logo_upload_id: logo.id}.to_json),
        ).save!
        group = signage_group(authority, user, Model::Permissions::Read | Model::Permissions::Create)
        source = Model::Generator.upload(uploader: user, storage_id: storage.id)
        source.file_name = "source.png"
        source.save!

        HttpMocks.signage_ai_vendor
        HttpMocks.signage_ai_storage

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {
            prompt:           "make it warmer",
            candidates:       1,
            group_id:         group.id,
            include_logo:     true,
            source_upload_id: source.id,
          }.to_json,
        )

        result.status_code.should eq 202
        job = Model::SignageAIJob.find!(UUID.new(JSON.parse(result.body)["id"].as_s))
        job.upload_ids.should contain logo.id
      end

      it "refuses a non-support caller who names no group" do
        authority, _, _ = setup_signage_ai
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        signage_group(authority, user, Model::Permissions::Read | Model::Permissions::Create)

        result = client.post(
          File.join(base, "generate"),
          headers: headers,
          body: {prompt: "a poster", candidates: 1}.to_json,
        )

        result.status_code.should eq 403
        Model::SignageAIJob.where(user_id: user.id.as(String)).to_a.should be_empty
      end

      it "refuses a caller with only Read on the group" do
        authority, _, _ = setup_signage_ai
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        group = signage_group(authority, user, Model::Permissions::Read)

        result = client.post(
          File.join(base, "generate"),
          headers: headers,
          body: {prompt: "a poster", candidates: 1, group_id: group.id}.to_json,
        )

        result.status_code.should eq 403
      end

      it "refuses a group that is not in the signage subsystem" do
        authority, _, _ = setup_signage_ai
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        root = Model::Generator.group(authority: authority).save!
        group = Model::Generator.group(authority: authority, parent: root).save!
        permissions = Model::Permissions::Read | Model::Permissions::Create
        Model::Generator.group_user(user: user, group: group, permissions: permissions).save!

        result = client.post(
          File.join(base, "generate"),
          headers: headers,
          body: {prompt: "a poster", candidates: 1, group_id: group.id}.to_json,
        )

        result.status_code.should eq 403
      end

      it "answers 429 once the caller has spent their day's allowance" do
        setup_signage_ai(quotas: {"user_per_day" => JSON::Any.new(1_i64)})
        _, headers = Spec::Authentication.authentication

        result = client.post(
          File.join(base, "generate"),
          headers: headers,
          body: {prompt: "a poster", candidates: 2}.to_json,
        )

        result.status_code.should eq 429
        JSON.parse(result.body)["kind"].as_s.should eq "quota"
      end

      it "records a vendor refusal against the job as a moderation failure" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication

        HttpMocks.signage_ai_vendor_refused
        HttpMocks.signage_ai_storage

        result = client.post(
          File.join(base, "generate"),
          headers: headers,
          body: {prompt: "a photograph of a real person", candidates: 1}.to_json,
        )

        result.status_code.should eq 202

        final = await_signage_ai_job(base, JSON.parse(result.body)["id"].as_s, headers)
        final["state"].as_s.should eq "failed"
        final["error_kind"].as_s.should eq "moderation"
        final["images_produced"].as_i.should eq 0
      end

      it "refuses a write with a read-only scope" do
        setup_signage_ai
        _, scoped_headers = Spec::Authentication.authentication(
          scope: [Model::UserJWT::Scope.new("signage_ai", :read)],
        )

        result = client.post(
          File.join(base, "generate"),
          headers: scoped_headers,
          body: {prompt: "a poster", candidates: 1}.to_json,
        )

        result.status_code.should eq 403
      end
    end

    describe "edit" do
      it "refuses a source the caller neither owns nor can reach through an item" do
        authority, storage, _ = setup_signage_ai
        user, headers = Spec::Authentication.authentication(sys_admin: false, support: false)
        group = signage_group(authority, user, Model::Permissions::Read | Model::Permissions::Create)

        owner = Model::Generator.user(authority: authority).save!
        upload = Model::Generator.upload(uploader: owner, storage_id: storage.id).save!

        # the item exists, but it is linked to no group the caller belongs to
        item = Model::Generator.item(authority: authority, media_id: upload.id).save!

        result = client.post(
          File.join(base, "edit"),
          headers: headers,
          body: {
            prompt:           "make it warmer",
            candidates:       1,
            group_id:         group.id,
            source_upload_id: upload.id,
            source_item_id:   item.id,
          }.to_json,
        )

        result.status_code.should eq 403
        JSON.parse(result.body)["kind"].as_s.should eq "permission"
      end
    end

    describe "the long poll" do
      it "returns as soon as the version moves" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        job = Model::Generator.signage_ai_job(user: user, provider: provider).save!
        job_id = job.id.as(UUID)

        spawn do
          sleep 700.milliseconds
          Model::SignageAIJob.bump_version(job_id)
        end

        started = Time.utc
        result = client.get(
          File.join(base, "jobs", job_id.to_s) + "?wait=20&since=#{job.version}",
          headers: headers,
        )
        elapsed = Time.utc - started

        result.status_code.should eq 200
        JSON.parse(result.body)["version"].as_i.should eq job.version + 1
        elapsed.should be < 10.seconds
      end

      it "returns after the wait when nothing moves" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        job = Model::Generator.signage_ai_job(user: user, provider: provider).save!

        started = Time.utc
        result = client.get(File.join(base, "jobs", job.id.to_s) + "?wait=1", headers: headers)
        elapsed = Time.utc - started

        result.status_code.should eq 200
        JSON.parse(result.body)["version"].as_i.should eq job.version
        elapsed.should be >= 900.milliseconds
      end

      it "hides a job belonging to another domain" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication

        other = Model::Generator.authority(domain: "ai-spec-#{random_name}.example.com").save!
        job = Model::Generator.signage_ai_job(authority: other).save!

        result = client.get(File.join(base, "jobs", job.id.to_s), headers: headers)
        result.status_code.should eq 404

        other.destroy
      end
    end

    describe "jobs" do
      it "lists only the caller's own jobs" do
        authority, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication

        mine = Model::Generator.signage_ai_job(user: user, provider: provider).save!
        someone_else = Model::Generator.user(authority: authority).save!
        theirs = Model::Generator.signage_ai_job(user: someone_else, provider: provider).save!

        result = client.get(File.join(base, "jobs") + "?mine=true", headers: headers)
        result.status_code.should eq 200

        ids = JSON.parse(result.body).as_a.map(&.["id"].as_s)
        ids.should contain mine.id.to_s
        ids.should_not contain theirs.id.to_s
      end

      it "only lets support see the whole domain" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        result = client.get(File.join(base, "jobs") + "?mine=false", headers: headers)
        result.status_code.should eq 403
      end
    end

    describe "cancel" do
      it "flags a job the caller owns" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication
        job = Model::Generator.signage_ai_job(user: user, provider: provider).save!

        result = client.post(File.join(base, "jobs", job.id.to_s, "cancel"), headers: headers)
        result.status_code.should eq 200
        JSON.parse(result.body)["version"].as_i.should eq job.version + 1

        stored = Model::SignageAIJob.find!(job.id.as(UUID))
        stored.cancel_requested.should be_true
      end

      it "refuses somebody else's job" do
        authority, _, provider = setup_signage_ai
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        someone_else = Model::Generator.user(authority: authority).save!
        job = Model::Generator.signage_ai_job(user: someone_else, provider: provider).save!

        result = client.post(File.join(base, "jobs", job.id.to_s, "cancel"), headers: headers)
        result.status_code.should eq 403
        Model::SignageAIJob.find!(job.id.as(UUID)).cancel_requested.should be_false
      end
    end

    describe "claim" do
      it "marks the candidate kept and records the item on the job" do
        _, storage, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication

        upload = Model::Generator.upload(uploader: user, storage_id: storage.id).save!
        upload.tags = [ImageGen::Store::CANDIDATE_TAG, "ai-job-spec"]
        upload.save!

        item = Model::Generator.item(media_id: upload.id).save!

        job = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1)
        job.state = Model::SignageAIJob::State::Done
        job.result = JSON.parse({images: [{state: "done", index: 0, upload_id: upload.id}]}.to_json)
        job.save!

        result = client.post(
          File.join(base, "jobs", job.id.to_s, "claim"),
          headers: headers,
          body: {upload_id: upload.id, item_id: item.id}.to_json,
        )

        result.status_code.should eq 200
        JSON.parse(result.body)["images"].as_a.first["item_id"].as_s.should eq item.id

        kept = Model::Upload.find!(upload.id.as(String))
        kept.tags.should contain "ai-claimed"
        kept.tags.should_not contain ImageGen::Store::CANDIDATE_TAG
      end

      # The app draws the words over the artwork and saves a flattened copy, so
      # the item's file is a new upload derived from the candidate rather than
      # the candidate itself. Requiring them to be the same upload meant a claim
      # never succeeded for a poster with any words on it.
      it "records the item when it is a flattened copy rather than the candidate" do
        _, storage, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication

        candidate = Model::Generator.upload(uploader: user, storage_id: storage.id).save!
        flattened = Model::Generator.upload(uploader: user, storage_id: storage.id).save!
        item = Model::Generator.item(media_id: flattened.id).save!

        job = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1)
        job.state = Model::SignageAIJob::State::Done
        job.result = JSON.parse({images: [{state: "done", index: 0, upload_id: candidate.id}]}.to_json)
        job.images_produced = 1
        job.save!

        result = client.post(
          File.join(base, "jobs", job.id.to_s, "claim"),
          headers: headers,
          body: {upload_id: candidate.id, item_id: item.id}.to_json,
        )

        result.status_code.should eq 200

        stored = Model::SignageAIJob.find!(job.id.as(UUID))
        stored.images.first["item_id"].as_s.should eq item.id
        # claiming records, it does not produce: counting again inflated usage
        stored.images_produced.should eq 1
      end

      it "refuses an item from another domain" do
        _, storage, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication

        other = Model::Generator.authority("other-#{UUID.random}.example.com").save!
        upload = Model::Generator.upload(uploader: user, storage_id: storage.id).save!
        item = Model::Generator.item(media_id: upload.id)
        item.authority_id = other.id
        item.save!

        job = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 1)
        job.state = Model::SignageAIJob::State::Done
        job.result = JSON.parse({images: [{state: "done", index: 0, upload_id: upload.id}]}.to_json)
        job.save!

        result = client.post(
          File.join(base, "jobs", job.id.to_s, "claim"),
          headers: headers,
          body: {upload_id: upload.id, item_id: item.id}.to_json,
        )

        result.status_code.should eq 403
      end
    end

    describe "usage" do
      it "sums spend per provider and model" do
        _, _, provider = setup_signage_ai
        user, headers = Spec::Authentication.authentication

        job = Model::Generator.signage_ai_job(user: user, provider: provider, candidates: 2)
        job.state = Model::SignageAIJob::State::Done
        job.images_produced = 2
        job.cost_units = 12.5
        job.save!

        result = client.get(File.join(base, "usage"), headers: headers)
        result.status_code.should eq 200

        rows = Array(Model::SignageAIJob::UsageRow).from_json(result.body)
        row = rows.find! { |entry| entry.provider == "OPENAI" }
        row.model.should eq "gpt-image-2"
        row.jobs.should eq 1
        row.candidates.should eq 2
        row.images_produced.should eq 2
        row.cost_units.should eq 12.5
      end

      it "is support only" do
        setup_signage_ai
        _, headers = Spec::Authentication.authentication(sys_admin: false, support: false)

        result = client.get(File.join(base, "usage"), headers: headers)
        result.status_code.should eq 403
      end
    end
  end
end
