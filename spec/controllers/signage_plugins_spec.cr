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

        sleep 1.second
        refresh_elastic(Model::SignagePlugin.table_name)

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
    end
  end
end
