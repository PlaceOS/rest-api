require "../lib/action-controller/spec/curl_context"

module PlaceOS::Api
  macro test_controller_scope(klass)
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
    {% else %}
      {% model_name = klass.stringify.gsub(/[s]$/, " ").strip %}
      {% model_gen = model_name.underscore %}
    {% end %}

    {% scope_name = klass.stringify.underscore %}

    context "read2" do
      it "allows access to show" do
        _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = show_route({{ base }}, id, authorization_header)
        result.status_code.should eq 200
        response_model = Model::{{ model_name.id }}.from_trusted_json(result.body)
        response_model.id.should eq id
        model.destroy
      end

      it "allows access to index" do
        _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        result = index_route({{ base }}, authorization_header)
        result.success?.should be_true
      end

      it "should not allow access to create" do
        _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        body = PlaceOS::Model::Generator.{{ model_gen.id }}.to_json
        result = create_route({{ base }}, body, authorization_header)
        result.status_code.should eq 403
      end

      it "should not allow access to delete" do
        _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = delete_route({{ base }}, id, authorization_header)
        result.status_code.should eq 403
        Model::{{ model_name.id }}.find(id).should_not be_nil
      end
    end

    context "write2" do
      it "should not allow access to show" do
        _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = show_route({{ base }}, id, authorization_header)
        result.status_code.should eq 403
        model.destroy
      end

      it "should not allow access to index" do
        _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        result = index_route({{ base }}, authorization_header)
        result.status_code.should eq 403
      end

      it "should allow access to create" do
        _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        body = PlaceOS::Model::Generator.{{ model_gen.id }}.to_json
        result = create_route({{ base }}, body, authorization_header)
        result.success?.should be_true

        body = result.body.as(String)
        response_model = Model::{{ model_name.id }}.from_trusted_json(result.body)
        response_model.destroy
      end

      it "should allow access to delete" do
        _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])
        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = delete_route({{ base }}, id, authorization_header)
        result.success?.should be_true
        Model::{{ model_name.id }}.find(id).should be_nil
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
    _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, PlaceOS::Model::UserJWT::Scope::Access::Write)])
          model = Model::Generator.{{ model_gen.id }}.save!
          original_name = model.name
          model.name = UUID.random.to_s

          id = model.id.as(String)
          path = base + id
          result = update_route(path, model, authorization_header)

          result.success?.should be_true
          updated = Model::{{ model_name.id }}.from_trusted_json(result.body)

          updated.id.should eq model.id
          updated.name.should_not eq original_name
          updated.destroy

          _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, PlaceOS::Model::UserJWT::Scope::Access::Read)])
          result = update_route(path, model, authorization_header)

          result.success?.should be_false
          result.status_code.should eq 403
    end
  end
end

def show_route(base, id, authorization_header)
  curl(
    method: "GET",
    path: base + id,
    headers: authorization_header,
  )
end

def index_route(base, authorization_header)
  curl(
    method: "GET",
    path: base,
    headers: authorization_header.merge({"Content-Type" => "application/json"}),
  )
end

def create_route(base, body, authorization_header)
  curl(
    method: "POST",
    path: base,
    body: body,
    headers: authorization_header.merge({"Content-Type" => "application/json"}),
  )
end

def delete_route(base, id, authorization_header)
  curl(
    method: "DELETE",
    path: base + id,
    headers: authorization_header,
  )
end

def update_route(path, body, authorization_header)
  curl(
    method: "PATCH",
    path: path,
    body: body.to_json,
    headers: authorization_header.merge({"Content-Type" => "application/json"}),
  )
end
