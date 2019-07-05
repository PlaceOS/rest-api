require "spec"
require "random"
require "rethinkdb-orm"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"

# Application config
require "../src/config"

# Generators for Engine models
require "./models/generator"

# Configure DB
db_name = "engine_#{ENV["SG_ENV"]? || "development"}"

RethinkORM::Connection.configure do |settings|
  settings.db = db_name
end

# Clear test tables on exit
at_exit do
  RethinkORM::Connection.raw do |q|
    q.db(db_name).table_list.for_each do |t|
      q.db(db_name).table(t).delete
    end
  end
  # Elastic.empty_indices
end

# Models
#################################################################

# Pretty prints document errors
def inspect_error(error : RethinkORM::Error::DocumentInvalid)
  errors = error.model.errors.map do |e|
    {
      field:   e.field,
      message: e.message,
    }
  end
  pp! errors
end

# Helper to check if string is encrypted
def is_encrypted?(string : String)
  string.starts_with? '\e'
end

# API
########################################################################

# Yield an authenticated user, and a header with Authorization bearer set
def authentication
  authenticated_user = Engine::Model::Generator.user.not_nil!
  authenticated_user.sys_admin = true
  authenticated_user.support = true
  authenticated_user.save!
  authorization_header = {
    "Authorization" => "Bearer #{Engine::Model::Generator.jwt(authenticated_user).encode}",
  }
  {authenticated_user, authorization_header}
end

# Check application responds with 404 when model not present
def test_404(base, model_name, headers)
  it "404s if #{model_name} isn't present in database" do
    id = "#{model_name}-#{Random.rand(9999).to_s.ljust(4, '0')}"
    path = base + id
    result = curl("GET", path: path, headers: headers)
    result.status_code.should eq 404
  end
end

macro test_base_index(klass, controller_klass)
  {% klass_name = klass.stringify.split("::").last.underscore %}
  authenticated_user, authorization_header = authentication

  it "queries #{ {{ klass_name }} }" do
    doc = Engine::Model::Generator.{{ klass_name.id }}.save!
    doc.persisted?.should be_true

    sleep 2

    params = HTTP::Params.encode({"q" => doc.id.not_nil!})
    path = "#{{{controller_klass}}::NAMESPACE[0]}?#{params}"
    result = curl(
      method: "GET",
      path: path,
      headers: authorization_header,
    )

    puts result.body unless result.success?

    result.status_code.should eq 200
    contains_search_term = JSON.parse(result.body)["results"].as_a.any? { |result| result["id"] == doc.id }
    contains_search_term.should be_true
  end
end

macro test_crd(klass, controller_klass)
  {% klass_name = klass.stringify.split("::").last.underscore %}
  base = {{ controller_klass }}::NAMESPACE[0]
  authenticated_user, authorization_header = authentication

  it "create" do
    body = Engine::Model::Generator.{{ klass_name.id }}.to_json
    result = curl(
      method: "POST",
      path: base,
      body: body,
      headers: authorization_header.merge({"Content-Type" => "application/json"}),
    )

    result.status_code.should eq 201
    body = result.body.not_nil!

    {{ klass }}.find(JSON.parse(body)["id"].as_s).try &.destroy
  end

  it "show" do
    model = Engine::Model::Generator.{{ klass_name.id }}.save!
    model.persisted?.should be_true
    id = model.id.not_nil!
    result = curl(
      method: "GET",
      path: base + id,
      headers: authorization_header,
    )

    result.status_code.should eq 200
    response_model = {{ klass.id }}.from_json(result.body).not_nil!
    response_model.id.should eq id

    model.destroy
  end

  it "destroy" do
    model = Engine::Model::Generator.{{ klass_name.id }}.save!
    model.persisted?.should be_true
    id = model.id.not_nil!
    result = curl(
      method: "DELETE",
      path: base + id,
      headers: authorization_header,
    )

    result.status_code.should eq 200
    {{ klass.id }}.find(id).should be_nil
  end
end
