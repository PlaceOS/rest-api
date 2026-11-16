require "../helper"

module PlaceOS::Api
  private def self.organisation_mqtt_access(topic : String, user : Model::User, access : Int32 = 4)
    headers = Spec::Tenancy.headers(user)
    # Mosquitto calls REST on its service hostname, not the token's domain.
    headers["Host"] = "broker.internal"
    query = URI::Params.encode({"topic" => topic, "acc" => access.to_s})
    client.post("#{MQTT.base_route}access?#{query}", headers: headers)
  end

  describe "organisation MQTT isolation" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if cleanup = fixture
        Spec::Tenancy.teardown(cleanup)
        fixture = nil
      end
    end

    it "allows a concrete owned authority topic and denies foreign or unbounded subscriptions" do
      f = fixture = Spec::Tenancy.build
      organisation_mqtt_access("placeos/#{f.acadian.authority.id}/metadata/changed", f.acadian.user).status_code.should eq 200
      organisation_mqtt_access("placeos/#{f.ucla.authority.id}/metadata/changed", f.acadian.user).status_code.should eq 403
      {"#", "placeos/+/#", "placeos/internal/chat/#", "placeos/org/metadata/#"}.each do |topic|
        organisation_mqtt_access(topic, f.acadian.user).status_code.should eq 403
      end
    end

    it "scopes source metadata by the concrete model rather than the common org topic label" do
      f = fixture = Spec::Tenancy.build
      organisation_mqtt_access("placeos/org/metadata/#{f.acadian.org_zone.id}", f.acadian.user).status_code.should eq 200
      organisation_mqtt_access("placeos/org/metadata/#{f.ucla.org_zone.id}", f.acadian.user).status_code.should eq 403
    end

    it "checks both the source state scope zone and its concrete system" do
      f = fixture = Spec::Tenancy.build
      own = "placeos/#{f.acadian.org_zone.id}/state/_/#{f.acadian.building.id}/_/_/#{f.acadian.system.id}/#{f.acadian.mod.driver_id}/#{f.acadian.mod.resolved_name}/1/power"
      foreign = "placeos/#{f.ucla.org_zone.id}/state/_/#{f.ucla.building.id}/_/_/#{f.ucla.system.id}/#{f.ucla.mod.driver_id}/#{f.ucla.mod.resolved_name}/1/power"
      organisation_mqtt_access(own, f.acadian.user).status_code.should eq 200
      organisation_mqtt_access(foreign, f.acadian.user).status_code.should eq 403
      spoofed = own.sub(f.acadian.system.id.as(String), f.ucla.system.id.as(String))
      organisation_mqtt_access(spoofed, f.acadian.user).status_code.should eq 403
    end

    it "keeps an authority read grant exact and unable to publish" do
      f = fixture = Spec::Tenancy.build
      secondary = Model::Generator.authority("secondary.test")
      secondary.organisation_id = f.acadian.organisation.id
      secondary.save!
      Model::Grant.new(user_id: f.ucla.admin.id.as(String), scope_type: "authority", scope_id: f.acadian.authority.id.as(String), permissions: Model::Permissions::Read.to_i).save!
      own_domain = "placeos/#{f.acadian.authority.id}/event/changed"
      organisation_mqtt_access(own_domain, f.ucla.admin).status_code.should eq 200
      organisation_mqtt_access("placeos/#{secondary.id}/event/changed", f.ucla.admin).status_code.should eq 403
      organisation_mqtt_access(own_domain, f.ucla.admin, 2).status_code.should eq 403
      organisation_mqtt_access("placeos/org/metadata/#{f.acadian.org_zone.id}", f.ucla.admin).status_code.should eq 403
    end

    it "refreshes support privileges before allowing MQTT writes" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.acadian.support)
      f.acadian.support.support = false
      f.acadian.support.save!
      query = URI::Params.encode({"topic" => "placeos/#{f.acadian.authority.id}/control", "acc" => "2"})
      client.post("#{MQTT.base_route}access?#{query}", headers: headers).status_code.should eq 403
    end

    it "rejects expired JWTs even on established-connection ACL checks" do
      f = fixture = Spec::Tenancy.build
      headers = Spec::Tenancy.headers(f.acadian.user)
      original = Model::UserJWT.decode(headers["Authorization"].split(' ').last)
      expired = Model::UserJWT.new(iss: original.iss, iat: original.iat, exp: 1.second.ago, domain: original.domain, id: original.id, user: original.user, scope: original.scope)
      headers["Authorization"] = "Bearer #{expired.encode}"
      query = URI::Params.encode({"topic" => "placeos/#{f.acadian.authority.id}/event", "acc" => "4"})
      client.post("#{MQTT.base_route}access?#{query}", headers: headers).status_code.should eq 401
    end

    it "rejects an expired API key and an API key whose owner was deleted" do
      f = fixture = Spec::Tenancy.build
      key = Model::ApiKey.new(name: "MQTT #{random_name}")
      key.user = f.acadian.user
      credential = key.x_api_key.not_nil!
      key.save!
      headers = HTTP::Headers{"Authorization" => credential, "Host" => "broker.internal"}
      client.post("#{MQTT.base_route}user", headers: headers).status_code.should eq 200
      PgORM::Database.connection do |db|
        db.exec("UPDATE api_key SET expires_at = $1 WHERE id = $2", args: [1.second.ago, key.id.as(String)])
      end
      client.post("#{MQTT.base_route}user", headers: headers).status_code.should eq 401
      PgORM::Database.connection do |db|
        db.exec("UPDATE api_key SET expires_at = NULL WHERE id = $1", args: [key.id.as(String)])
      end
      f.acadian.user.deleted = true
      f.acadian.user.save!
      client.post("#{MQTT.base_route}user", headers: headers).status_code.should eq 401
    end

    it "preserves wildcard broker access for explicit management staff" do
      f = fixture = Spec::Tenancy.build
      organisation_mqtt_access("#", f.placeos.admin).status_code.should eq 200
      organisation_mqtt_access("placeos/#", f.placeos.admin, 2).status_code.should eq 200
    end

    it "retains the legacy ACL when enforcement is disabled" do
      f = fixture = Spec::Tenancy.build
      Utils::Tenancy.enforce = false
      organisation_mqtt_access("#", f.acadian.user).status_code.should eq 200
    end
  end
end
