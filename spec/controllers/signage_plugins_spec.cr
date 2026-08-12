require "../helper"

module PlaceOS::Api
  describe SignagePlugins do
    ::Spec.before_each do
      Model::SignagePlugin.clear
    end

    describe "/api/engine/v2/signage/plugins" do
      it "POST / creates a signage plugin" do
        headers = Spec::Authentication.headers

        body = {
          name:     "Test Plugin",
          uri:      "/plugins/test",
          params:   {} of String => JSON::Any,
          defaults: {} of String => JSON::Any,
        }.to_json

        result = client.post(
          path: SignagePlugins.base_route,
          body: body,
          headers: headers,
        )

        result.status_code.should eq 201
        created = Model::SignagePlugin.from_trusted_json(result.body)
        created.name.should eq "Test Plugin"
        created.uri.should eq "/plugins/test"
        created.destroy
      end

      it "GET /:id shows a signage plugin" do
        headers = Spec::Authentication.headers

        plugin = Model::Generator.signage_plugin.save!
        plugin_id = plugin.id.as(String)

        result = client.get(
          path: File.join(SignagePlugins.base_route, plugin_id),
          headers: headers,
        )

        result.status_code.should eq 200
        shown = Model::SignagePlugin.from_trusted_json(result.body)
        shown.id.should eq plugin_id
      end

      it "PATCH /:id updates a signage plugin" do
        headers = Spec::Authentication.headers

        plugin = Model::Generator.signage_plugin.save!
        plugin_id = plugin.id.as(String)

        body = {name: "Updated Plugin"}.to_json

        result = client.patch(
          path: File.join(SignagePlugins.base_route, plugin_id),
          body: body,
          headers: headers,
        )

        result.status_code.should eq 200
        updated = Model::SignagePlugin.from_trusted_json(result.body)
        updated.name.should eq "Updated Plugin"
      end

      it "DELETE /:id removes a signage plugin" do
        headers = Spec::Authentication.headers

        plugin = Model::Generator.signage_plugin.save!
        plugin_id = plugin.id.as(String)

        result = client.delete(
          path: File.join(SignagePlugins.base_route, plugin_id),
          headers: headers,
        )

        result.status_code.should eq 202
        Model::SignagePlugin.find?(plugin_id).should be_nil
      end

      it "returns 404 for non-existent plugin" do
        headers = Spec::Authentication.headers

        result = client.get(
          path: File.join(SignagePlugins.base_route, "plugin-nonexistent"),
          headers: headers,
        )

        result.status_code.should eq 404
      end

      it "rejects invalid plugin on create" do
        headers = Spec::Authentication.headers

        body = {name: "", uri: "/plugins/test"}.to_json

        result = client.post(
          path: SignagePlugins.base_route,
          body: body,
          headers: headers,
        )

        result.status_code.should eq 422
      end

      it "GET / includes shared plugins in results" do
        headers = Spec::Authentication.headers

        # create a shared plugin (no authority)
        plugin = Model::Generator.signage_plugin
        plugin.authority_id = nil
        plugin.save!
        plugin_id = plugin.id.as(String)

        result = client.get(
          path: SignagePlugins.base_route,
          headers: headers,
        )

        result.status_code.should eq 200
        plugins = Array(JSON::Any).from_json(result.body)
        plugins.any? { |p| p["id"].as_s == plugin_id }.should be_true
      end

      it "GET /:id allows access to shared plugins (no authority_id)" do
        headers = Spec::Authentication.headers

        plugin = Model::Generator.signage_plugin
        plugin.authority_id = nil
        plugin.save!
        plugin_id = plugin.id.as(String)

        result = client.get(
          path: File.join(SignagePlugins.base_route, plugin_id),
          headers: headers,
        )

        result.status_code.should eq 200
        shown = Model::SignagePlugin.from_trusted_json(result.body)
        shown.id.should eq plugin_id
        shown.authority_id.should be_nil
      end

      it "PATCH /:id allows updating shared plugins" do
        headers = Spec::Authentication.headers

        plugin = Model::Generator.signage_plugin
        plugin.authority_id = nil
        plugin.save!
        plugin_id = plugin.id.as(String)

        body = {name: "Updated Shared Plugin"}.to_json

        result = client.patch(
          path: File.join(SignagePlugins.base_route, plugin_id),
          body: body,
          headers: headers,
        )

        result.status_code.should eq 200
        updated = Model::SignagePlugin.from_trusted_json(result.body)
        updated.name.should eq "Updated Shared Plugin"
        updated.authority_id.should be_nil
      end

      it "GET / lists this domain's plugins and filters with q", tags: "search" do
        headers = Spec::Authentication.headers

        target = random_name
        match = Model::Generator.signage_plugin(name: target).save!
        other = Model::Generator.signage_plugin(name: random_name).save!

        result = client.get(path: SignagePlugins.base_route, headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(match.id.as(String))
        ids.should contain(other.id.as(String))
        result.headers["X-Total-Count"].should eq "2"

        params = HTTP::Params.encode({"q" => target})
        result = client.get(path: "#{SignagePlugins.base_route}?#{params}", headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(match.id.as(String))
        ids.should_not contain(other.id.as(String))
        result.headers["X-Total-Count"].should eq "1"
      end

      it "GET / excludes other authorities' plugins", tags: "search" do
        headers = Spec::Authentication.headers

        mine = Model::Generator.signage_plugin.save!

        shared = Model::Generator.signage_plugin
        shared.authority_id = nil
        shared.save!

        other_authority = Model::Generator.authority("https://other-#{random_name}.example.com").save!
        foreign = Model::Generator.signage_plugin(authority: other_authority).save!

        result = client.get(path: SignagePlugins.base_route, headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(mine.id.as(String))
        ids.should contain(shared.id.as(String))
        ids.should_not contain(foreign.id.as(String))
        result.headers["X-Total-Count"].should eq "2"
      end

      it "GET /?enabled= filters on both true and false", tags: "search" do
        headers = Spec::Authentication.headers

        enabled_name = random_name
        enabled_plugin = Model::Generator.signage_plugin(name: enabled_name)
        enabled_plugin.enabled = true
        enabled_plugin.save!

        disabled_plugin = Model::Generator.signage_plugin
        disabled_plugin.enabled = false
        disabled_plugin.save!

        result = client.get(path: "#{SignagePlugins.base_route}?enabled=true", headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(enabled_plugin.id.as(String))
        ids.should_not contain(disabled_plugin.id.as(String))

        # enabled=false must filter too, not be ignored
        result = client.get(path: "#{SignagePlugins.base_route}?enabled=false", headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should contain(disabled_plugin.id.as(String))
        ids.should_not contain(enabled_plugin.id.as(String))

        # q combines with the enabled filter
        params = HTTP::Params.encode({"q" => enabled_name, "enabled" => "true"})
        result = client.get(path: "#{SignagePlugins.base_route}?#{params}", headers: headers)
        result.status_code.should eq 200
        ids = Array(Hash(String, JSON::Any))
          .from_json(result.body)
          .map(&.["id"].as_s)
        ids.should eq [enabled_plugin.id.as(String)]

        params = HTTP::Params.encode({"q" => enabled_name, "enabled" => "false"})
        result = client.get(path: "#{SignagePlugins.base_route}?#{params}", headers: headers)
        result.status_code.should eq 200
        Array(JSON::Any).from_json(result.body).should be_empty
        result.headers["X-Total-Count"].should eq "0"
      end

      it "GET / paginates deterministically by name", tags: "search" do
        headers = Spec::Authentication.headers

        first = Model::Generator.signage_plugin(name: "aaa-#{random_name}").save!
        second = Model::Generator.signage_plugin(name: "bbb-#{random_name}").save!

        result = client.get(path: "#{SignagePlugins.base_route}?limit=1", headers: headers)
        result.status_code.should eq 200
        page = Array(Hash(String, JSON::Any)).from_json(result.body)
        page.size.should eq 1
        page.first["id"].as_s.should eq first.id.as(String)
        result.headers["X-Total-Count"].should eq "2"
        result.headers["Link"]?.should_not be_nil

        result = client.get(path: "#{SignagePlugins.base_route}?limit=1&offset=1", headers: headers)
        result.status_code.should eq 200
        page = Array(Hash(String, JSON::Any)).from_json(result.body)
        page.size.should eq 1
        page.first["id"].as_s.should eq second.id.as(String)
      end
    end
  end
end
