require "spec"
require "rethinkdb-orm"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"

# Generators for Engine models
require "../lib/engine-models/spec/generator"

# Configure DB
DB_NAME = "test_#{Time.now.to_unix}_#{rand(10000)}"
RethinkORM::Connection.configure do |settings|
  settings.db = DB_NAME
end

# Tear down the test database
at_exit do
  RethinkORM::Connection.raw do |q|
    q.db_drop(DB_NAME)
  end
end

# Check application responds with 404 when model not present
def test_404(namespace, model_name)
  it "404s if #{model_name} isn't present in database" do
    id = "#{model_name}-#{Random.rand(9999).to_s.ljust(4, '0')}"
    path = namespace[0] + id
    result = curl("GET", path)
    result.status_code.should eq 404
  end
end

macro test_crd(klass, controller_klass)
  {% klass_name = klass.stringify.split("::").last.underscore %}
  base = {{ controller_klass }}::NAMESPACE[0]

  it "create" do
    body = Model::Generator.{{ klass_name.id }}.to_json
    result = curl(
      method: "POST",
      path: base,
      body: body,
      headers: {"Content-Type" => "application/json"},
    )

    result.status_code.should eq 201
    body = result.body.not_nil!

    {{ klass }}.find(JSON.parse(body)["id"].as_s).try &.destroy
  end

  it "show" do
    model = Engine::Model::Generator.{{ klass_name.id }}.save!
    model.persisted?.should be_true
    id = model.id.not_nil!
    result = curl(method: "GET", path: base + id)

    result.status_code.should eq 200
    response_model = {{ klass.id }}.from_json(result.body).not_nil!
    response_model.id.should eq id

    model.destroy
  end

  it "destroy" do
    model = Engine::Model::Generator.{{ klass_name.id }}.save!
    model.persisted?.should be_true
    id = model.id.not_nil!
    result = curl(method: "DELETE", path: base + id)

    result.status_code.should eq 200
    {{ klass.id }}.find(id).should be_nil
  end
end
