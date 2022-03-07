require "http"
require "mutex"
require "promise"
require "random"
require "rethinkdb-orm"
require "simple_retry"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"

require "./spec_constants"
require "./scope_helper"
require "./http_mocks"

Spec.before_suite do
  Log.builder.bind("*", backend: PlaceOS::LogBackend::STDOUT, level: :trace)
  clear_tables
end

Spec.before_each do
  PlaceOS::Api::HttpMocks.reset
end

Spec.after_suite { clear_tables }

# Application config
require "../src/config"

# Generators for Engine models
require "placeos-models/spec/generator"
require "spec"

# Configure DB
db_name = "place_#{ENV["SG_ENV"]? || "development"}"

RethinkORM.configure &.db=(db_name)

def clear_tables
  {% begin %}
    Promise.all(
      {% for t in {
                    PlaceOS::Model::Asset,
                    PlaceOS::Model::AssetInstance,
                    PlaceOS::Model::ControlSystem,
                    PlaceOS::Model::Driver,
                    PlaceOS::Model::Module,
                    PlaceOS::Model::Repository,
                    PlaceOS::Model::Settings,
                    PlaceOS::Model::Trigger,
                    PlaceOS::Model::TriggerInstance,
                    PlaceOS::Model::Zone,
                  } %}
        Promise.defer { {{t.id}}.clear },
      {% end %}
    )
  {% end %}
end

CREATION_LOCK = Mutex.new(protection: :reentrant)

# Yield an authenticated user, and a header with X-API-Key set
def x_api_authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC])
  CREATION_LOCK.synchronize do
    user, _header = authentication(sys_admin, support, scope)
    unless api_key = user.api_tokens.first?
      api_key = PlaceOS::Model::ApiKey.new
      api_key.user = user
      api_key.name = user.name
      api_key.save!
    end

    authorization_header = {
      "X-API-Key" => api_key.x_api_key.not_nil!,
    }

    {api_key.user, authorization_header}
  end
end

# Yield an authenticated user, and a header with Authorization bearer set
# This method is synchronised due to the redundant top-level calls.
def authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC])
  CREATION_LOCK.synchronize do
    test_user_email = PlaceOS::Model::Email.new("test-admin-#{sys_admin ? "1" : "0"}-supp-#{support ? "1" : "0"}-rest-api@place.tech")
    existing = PlaceOS::Model::User.where(email: test_user_email).first?

    authenticated_user = if existing
                           existing
                         else
                           user = PlaceOS::Model::Generator.user
                           user.sys_admin = sys_admin
                           user.support = support
                           user.save!
                         end
    authorization_header = {
      "Authorization" => "Bearer #{PlaceOS::Model::Generator.jwt(authenticated_user, scope).encode}",
    }
    {authenticated_user, authorization_header}
  end
end

def generate_auth_user(sys_admin, support, scopes)
  scope_list = scopes.try &.join('-', &.to_s)
  test_user_email = PlaceOS::Model::Email.new("test-#{"admin-" if sys_admin}#{"supp" if support}-scope-#{scope_list}-rest-api@place.tech")
  existing = PlaceOS::Model::User.where(email: test_user_email).first?

  existing || PlaceOS::Model::Generator.user.tap do |user|
    user.email = test_user_email
    user.sys_admin = sys_admin
    user.support = support
    user.save!
  end
end

def until_expected(method, path, headers, timeout : Time::Span = 3.seconds, &block : HTTP::Client::Response -> Bool)
  channel = Channel(Bool).new
  spawn do
    before = Time.utc
    begin
      SimpleRetry.try_to(base_interval: 50.milliseconds, max_elapsed_time: 2.seconds, retry_on: Exception) do
        result = curl(method: method, path: path, headers: headers)

        unless result.success?
          puts "\nrequest failed with: #{result.status_code}"
          puts result.body
        end

        expected = block.call(result)

        raise Exception.new("retry") unless expected || channel.closed?
        channel.send(true) if expected
      end
    rescue e
      raise e unless e.message == "retry"
    ensure
      after = Time.utc
      puts "took #{(after - before).milliseconds}ms"
    end
  end

  spawn do
    sleep timeout
    channel.close
  rescue
  end

  success = channel.receive?
  channel.close
  !!success
end

def random_name
  UUID.random.to_s.split('-').first
end

def refresh_elastic(index : String? = nil)
  path = "/_refresh"
  path = "/#{index}" + path unless index.nil?
  Neuroplastic::Client.new.perform_request("POST", path)
end

module PlaceOS::Api::Specs
  # Check application responds with 404 when model not present
  def self.test_404(base, model_name, headers)
    it "404s if #{model_name} isn't present in database", tags: "search" do
      id = "#{model_name}-#{Random.rand(9999).to_s.ljust(4, '0')}"
      path = base + id
      result = curl("GET", path: path, headers: headers)
      result.status_code.should eq 404
    end
  end

  # Test search on name field
  macro test_base_index(klass, controller_klass)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "queries #{ {{ klass_name }} }", tags: "search" do
      _, authorization_header = authentication
      doc = PlaceOS::Model::Generator.{{ klass_name.id }}
      name = random_name
      doc.name = name
      doc.save!

      refresh_elastic({{klass}}.table_name)

      doc.persisted?.should be_true
      params = HTTP::Params.encode({"q" => name})
      path = "#{{{controller_klass}}::NAMESPACE[0].rstrip('/')}?#{params}"
      header = authorization_header

      found = until_expected("GET", path, header) do |response|
        Array(Hash(String, JSON::Any))
          .from_json(response.body)
          .map(&.["id"].as_s)
          .any?(doc.id)
      end
      found.should be_true
    end
  end

  macro test_create(klass, controller_klass)
    {% klass_name = klass.stringify.split("::").last.underscore %}
    base = {{ controller_klass }}::NAMESPACE[0]

    it "create" do
      _, authorization_header = authentication
      body = PlaceOS::Model::Generator.{{ klass_name.id }}.to_json
      result = curl(
        method: "POST",
        path: base,
        body: body,
        headers: authorization_header.merge({"Content-Type" => "application/json"}),
      )

      result.status_code.should eq 201
      response_model = {{ klass.id }}.from_trusted_json(result.body)
      response_model.destroy
    end
  end

  macro test_show(klass, controller_klass)
    {% klass_name = klass.stringify.split("::").last.underscore %}
    base = {{ controller_klass }}::NAMESPACE[0]

    it "show" do
      _, authorization_header = authentication
      model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
      model.persisted?.should be_true
      id = model.id.as(String)
      result = curl(
        method: "GET",
        path: base + id,
        headers: authorization_header,
      )

      result.status_code.should eq 200
      response_model = {{ klass.id }}.from_trusted_json(result.body)
      response_model.id.should eq id

      model.destroy
    end
  end

  macro test_destroy(klass, controller_klass)
    {% klass_name = klass.stringify.split("::").last.underscore %}
    base = {{ controller_klass }}::NAMESPACE[0]

    it "destroy" do
      _, authorization_header = authentication
      model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
      model.persisted?.should be_true
      id = model.id.as(String)
      result = curl(
        method: "DELETE",
        path: base + id,
        headers: authorization_header,
      )

      result.status_code.should eq 200
      {{ klass.id }}.find(id).should be_nil
    end
  end

  macro test_crd(klass, controller_klass)
    Specs.test_create({{ klass }}, {{ controller_klass }})
    Specs.test_show({{ klass }}, {{ controller_klass }})
    Specs.test_destroy({{ klass }}, {{ controller_klass }})
  end

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

    context "read" do
      it "allows access to show" do
        _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = show_route({{ base }}, id, scoped_authorization_header)
        result.status_code.should eq 200
        response_model = Model::{{ model_name.id }}.from_trusted_json(result.body)
        response_model.id.should eq id
        model.destroy
      end

      it "allows access to index" do
        _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        result = index_route({{ base }}, scoped_authorization_header)
        result.success?.should be_true
      end

      it "should not allow access to create" do
        _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        body = PlaceOS::Model::Generator.{{ model_gen.id }}.to_json
        result = create_route({{ base }}, body, scoped_authorization_header)
        result.status_code.should eq 403
      end

      it "should not allow access to delete" do
        _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = delete_route({{ base }}, id, scoped_authorization_header)
        result.status_code.should eq 403
        Model::{{ model_name.id }}.find(id).should_not be_nil
      end
    end

    context "write" do
      it "should not allow access to show" do
        _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = show_route({{ base }}, id, scoped_authorization_header)
        result.status_code.should eq 403
        model.destroy
      end

      it "should not allow access to index" do
        _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        result = index_route({{ base }}, scoped_authorization_header)
        result.status_code.should eq 403
      end

      it "should allow access to create" do
        _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        body = PlaceOS::Model::Generator.{{ model_gen.id }}.to_json
        result = create_route({{ base }}, body, scoped_authorization_header)
        result.success?.should be_true

        response_model = Model::{{ model_name.id }}.from_trusted_json(result.body)
        response_model.destroy
      end

      it "should allow access to delete" do
        _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])
        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = delete_route({{ base }}, id, scoped_authorization_header)
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
    _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, PlaceOS::Model::UserJWT::Scope::Access::Write)])
          model = Model::Generator.{{ model_gen.id }}.save!
          original_name = model.name
          model.name = random_name

          id = model.id.as(String)
          path = base + id
          result = update_route(path, model, scoped_authorization_header)

          result.success?.should be_true
          updated = Model::{{ model_name.id }}.from_trusted_json(result.body)

          updated.id.should eq model.id
          updated.name.should_not eq original_name
          updated.destroy

          _, scoped_authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, PlaceOS::Model::UserJWT::Scope::Access::Read)])
          result = update_route(path, model, scoped_authorization_header)

          result.success?.should be_false
          result.status_code.should eq 403
    end
  end
end
