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

  # A signage group the caller may act in, hung off a root group.
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
end
