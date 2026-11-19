require "spec"
require "../src/config"

describe "OpenAPI timestamp schemas" do
  it "describes timestamps using their serialized types" do
    refs = JSON::Schema::Definitions.new("#/components/schemas/")

    epoch = JSON.parse(%({"type":"integer","format":"Int64"}))
    date_time = JSON.parse(%({"type":"string","format":"date-time"}))
    null = JSON.parse(%({"type":"null"}))

    zone = JSON.parse(PlaceOS::Model::Zone.json_schema(refs: refs).to_json)["properties"]
    zone["created_at"]["anyOf"].as_a.to_set.should eq Set{epoch, null}
    zone["updated_at"]["anyOf"].as_a.to_set.should eq Set{epoch, null}

    api_key = JSON.parse(PlaceOS::Api::ApiKeys::Response.json_schema(refs: refs).to_json)["properties"]
    api_key["created_at"].should eq epoch
    api_key["expires_at"]["anyOf"].as_a.to_set.should eq Set{epoch, null}

    edge = JSON.parse(PlaceOS::Model::Edge::KeyResponse.json_schema(refs: refs).to_json)["properties"]
    edge["created_at"].should eq epoch
    edge["last_seen"]["anyOf"].as_a.to_set.should eq Set{epoch, null}

    shortener = JSON.parse(PlaceOS::Model::Shortener.json_schema(refs: refs).to_json)["properties"]
    shortener["valid_from"]["anyOf"].as_a.to_set.should eq Set{epoch, null}

    group = JSON.parse(PlaceOS::Model::Group.json_schema(refs: refs).to_json)["properties"]
    group["created_at"]["anyOf"].as_a.to_set.should eq Set{date_time, null}

    upload = JSON.parse(PlaceOS::Model::Upload.json_schema(refs: refs).to_json)["properties"]
    upload["cache_modified"]["anyOf"].as_a.to_set.should eq Set{date_time, null}
  end
end

describe "OpenAPI wire schemas" do
  it "includes response-only asset counts" do
    refs = JSON::Schema::Definitions.new("#/components/schemas/")
    asset_type = JSON.parse(PlaceOS::Model::AssetType.json_schema(refs: refs).to_json)
    count = asset_type["properties"]["asset_count"]
    variants = count["anyOf"]?.try(&.as_a) || [count]
    variants.map(&.["type"].as_s).should contain("integer")
    count["readOnly"].as_bool.should be_true
  end

  it "describes URI and scope values as strings" do
    refs = JSON::Schema::Definitions.new("#/components/schemas/")
    node = JSON.parse(PlaceOS::Api::Cluster::NodeStatus.json_schema(refs: refs).to_json)
    node["properties"]["uri"]["type"].as_s.should eq "string"

    api_key = JSON.parse(PlaceOS::Api::ApiKeys::Response.json_schema(refs: refs).to_json)
    api_key["properties"]["scopes"]["items"]["type"].as_s.should eq "string"
  end

  it "describes values from the enum converter" do
    refs = JSON::Schema::Definitions.new("#/components/schemas/")
    broker = JSON.parse(PlaceOS::Model::Broker.json_schema(refs: refs).to_json)
    variants = broker["properties"]["auth_type"]["anyOf"].as_a
    values = variants.find! { |schema| schema["enum"]? }["enum"].as_a
    values.should contain(JSON::Any.new(2_i64))
    variants.should contain(JSON.parse(%({"type":"null"})))
  end
end
