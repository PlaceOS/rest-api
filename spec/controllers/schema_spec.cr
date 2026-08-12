require "../helper"

module PlaceOS::Api
  describe Schema do
    Spec.test_404(Schema.base_route, model_name: Model::JsonSchema.table_name, headers: Spec::Authentication.headers, clz: String)

    describe "index", tags: "search" do
      Spec.test_base_index(Model::JsonSchema, Schema)

      it "lists schemas with a total count" do
        schema = PlaceOS::Model::Generator.json_schema
        name = random_name
        schema.name = name
        schema.save!

        result = client.get(Schema.base_route, headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        result.headers["X-Total-Count"].to_i.should be >= 1

        # a unique q scopes the count to exactly this record
        params = HTTP::Params.encode({"q" => name})
        result = client.get("#{Schema.base_route}?#{params}", headers: Spec::Authentication.headers)
        result.status_code.should eq 200
        result.headers["X-Total-Count"].should eq "1"
        schemas = Array(Hash(String, JSON::Any)).from_json(result.body)
        schemas.size.should eq 1
        schemas.first["id"].as_s.should eq schema.id

        schema.destroy
      end
    end
  end
end
