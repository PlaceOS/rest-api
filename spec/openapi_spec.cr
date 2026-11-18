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
