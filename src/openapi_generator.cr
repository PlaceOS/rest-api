# require "./constants"

require "./*"

require "openapi-generator"
require "openapi-generator/serializable"
require "openapi-generator/providers/action-controller"
require "openapi-generator/helpers/action-controller"

require "openapi-generator/serializable/adapters/active-model"

class Zone
  extend OpenAPI::Generator::Serializable

  def initialize(@name, @description, @tags); end

  @[OpenAPI::Field(type: String, example: "Zone #{Random.new.rand(5000)}")]
  property name : String
  @[OpenAPI::Field(type: String, example: "This zone has space for #{Random.new.rand(5000)} people")]
  property description : String
  property tags : Set(String)
end

# Produces an OpenAPI::Schema reference.
puts Zone.to_openapi_schema.to_yaml

macro finished
  OpenAPI::Generator::Helpers::ActionController.bootstrap

  OpenAPI::Generator.generate(
    OpenAPI::Generator::RoutesProvider::ActionController.new,
    options: {
      output: Path[Dir.current] / "openapi.yml",
    },
    base_document: {
      info:       {title: "PlaceOS Rest-API", version: PlaceOS::Api::VERSION},
      components: NamedTuple.new,
    }
  )

end
