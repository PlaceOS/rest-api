require "./authentication"

module PlaceOS::Api::Spec
  # Check application responds with 404 when model not present
  def self.test_404(base, model_name, headers : HTTP::Headers, clz : Class = String)
    it "404s if #{model_name} isn't present in database", tags: "search" do
      id = (clz < Int) ? Random.rand(9999).to_s : "#{model_name}-#{Random.rand(9999).to_s.ljust(4, '0')}"
      path = File.join(base, id)
      result = client.get(path, headers: headers)

      result.status_code.should eq 404
    end
  end

  # Test search on name field
  macro test_base_index(klass, controller_klass)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "queries #{ {{ klass_name }} }", tags: "search" do
      _, headers = Spec::Authentication.authentication
      doc = PlaceOS::Model::Generator.{{ klass_name.id }}
      name = random_name
      doc.name = name
      doc.save!

      refresh_elastic({{ klass }}.table_name)

      doc.persisted?.should be_true
      params = HTTP::Params.encode({"q" => name})
      path = "#{{{controller_klass}}.base_route.rstrip('/')}?#{params}"

      found = until_expected("GET", path, headers) do |response|
        Array(Hash(String, JSON::Any))
          .from_json(response.body)
          .map{|v| v.["id"].as_i64? || v.["id"].as_s?}
          .any?(doc.id)
      end
      found.should be_true
    end
  end

  macro test_create(klass, controller_klass)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "create" do
      body = PlaceOS::Model::Generator.{{ klass_name.id }}.to_json
      result = client.post(
        {{ controller_klass }}.base_route,
        body: body,
        headers: Spec::Authentication.headers
      )

      result.status_code.should eq 201
      response_model = {{ klass.id }}.from_trusted_json(result.body)
      response_model.destroy
    end
  end

  macro test_show(klass, controller_klass, id_type = String)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "show" do
      model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
      model.persisted?.should be_true
      id = model.id.as({{ id_type.id }})
      result = client.get(
        path: File.join({{ controller_klass }}.base_route, id.to_s),
        headers: Spec::Authentication.headers,
      )

      result.status_code.should eq 200
      response_model = {{ klass.id }}.from_trusted_json(result.body)
      response_model.id.should eq id

      model.destroy
    end
  end

  macro test_destroy(klass, controller_klass, id_type = String)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "destroy" do
      model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
      model.persisted?.should be_true
      id = model.id.as({{ id_type.id }})
      result = client.delete(
        path: File.join({{ controller_klass }}.base_route, id.to_s),
        headers: Spec::Authentication.headers
      )

      result.success?.should eq true
      {{ klass.id }}.find?(id).should be_nil
    end
  end

  macro test_crd(klass, controller_klass, id_type = String)
    Spec.test_create({{ klass }}, {{ controller_klass }})
    Spec.test_show({{ klass }}, {{ controller_klass }}, {{ id_type }})
    Spec.test_destroy({{ klass }}, {{ controller_klass }}, {{ id_type }})
  end

  macro test_controller_scope(klass, id_type = String)
    {% base = klass.resolve.constant(:NAMESPACE).first %}

    {% if klass.stringify == "Repositories" %}
      {% model_name = "Repository" %}
      {% model_gen = "repository" %}
    {% elsif klass.stringify == "Systems" %}
      {% model_name = "ControlSystem" %}
      {% model_gen = "control_system" %}
    {% elsif klass.stringify == "Settings" %}
      {% model_name = "Settings" %}
      {% model_gen = "settings" %}
    {% elsif klass.stringify == "AssetCategories" %}
      {% model_name = "AssetCategory" %}
      {% model_gen = "asset_category" %}
    {% else %}
      {% model_name = klass.stringify.gsub(/[s]$/, " ").strip %}
      {% model_gen = model_name.underscore %}
    {% end %}

    {% scope_name = klass.stringify.underscore %}

    context "read" do
      it "allows access to show" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as({{ id_type.id }})
        result = Scopes.show({{ base }}, id, scoped_headers)
        result.status_code.should eq 200
        response_model = Model::{{ model_name.id }}.from_trusted_json(result.body)
        response_model.id.should eq id
        model.destroy
      end

      it "allows access to index" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        result = Scopes.index({{ base }}, scoped_headers)
        result.success?.should be_true
      end

      it "should not allow access to create" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        body = PlaceOS::Model::Generator.{{ model_gen.id }}.to_json
        result = Scopes.create({{ base }}, body, scoped_headers)
        result.status_code.should eq 403
      end

      it "should not allow access to delete" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as({{ id_type.id }})
        result = Scopes.delete({{ base }}, id, scoped_headers)
        result.status_code.should eq 403
        Model::{{ model_name.id }}.find?(id).should_not be_nil
      end
    end

    context "write" do
      it "should not allow access to show" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as({{ id_type.id }})
        result = Scopes.show({{ base }}, id, scoped_headers)
        result.status_code.should eq 403
        model.destroy
      end

      it "should not allow access to index" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        result = Scopes.index({{ base }}, scoped_headers)
        result.status_code.should eq 403
      end

      it "should allow access to create" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        body = PlaceOS::Model::Generator.{{ model_gen.id }}.to_json
        result = Scopes.create({{ base }}, body, scoped_headers)
        result.success?.should be_true

        response_model = Model::{{ model_name.id }}.from_trusted_json(result.body)
        response_model.destroy
      end

      it "should allow access to delete" do
        _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])
        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as({{ id_type.id }})
        result = Scopes.delete({{ base }}, id, scoped_headers)
        result.success?.should be_true
        Model::{{ model_name.id }}.find?(id).should be_nil
      end
    end
  end

  macro test_update_write_scope(klass)
    {% base = klass.resolve.constant(:NAMESPACE).first %}

    {% if klass.stringify == "Repositories" %}
      {% model_name = "Repository" %}
      {% model_gen = "repository" %}
    {% else %}
      {% model_name = klass.stringify.gsub(/[s]$/, " ").strip %}
      {% model_gen = model_name.underscore %}
    {% end %}

    {% scope_name = klass.stringify.underscore %}

    it "checks scope on update" do
    _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, PlaceOS::Model::UserJWT::Scope::Access::Write)])
          model = Model::Generator.{{ model_gen.id }}.save!
          original_name = model.name
          model.name = random_name

          id = model.id.as(String)
          path = File.join({{ base }}, id)
          result = Scopes.update(path, model, scoped_headers)

          result.success?.should be_true
          updated = Model::{{ model_name.id }}.from_trusted_json(result.body)

          updated.id.should eq model.id
          updated.name.should_not eq original_name
          updated.destroy

          _, scoped_headers = Spec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, PlaceOS::Model::UserJWT::Scope::Access::Read)])
          result = Scopes.update(path, model, scoped_headers)

          result.success?.should be_false
          result.status_code.should eq 403
    end
  end
end
