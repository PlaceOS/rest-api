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

class Metadata
  extend OpenAPI::Generator::Serializable

  def initialize(@name, @description, @details, @editors); end

  @[OpenAPI::Field(type: String, example: "Orange Metadata")]
  property name : String
  @[OpenAPI::Field(type: String, example: "Includes size of orange & more...")]
  property description : String
  property details : JSON::Any
  property editors : Set(String)
end

class User
  extend OpenAPI::Generator::Serializable

  def initialize(@name); end

  @[OpenAPI::Field(type: String, example: "Robert")]
  property name : String
end

class ApiKey
  extend OpenAPI::Generator::Serializable

  def initialize(@name); end

  @[OpenAPI::Field(type: String, example: "Robert")]
  property name : String
end

class Auth
  extend OpenAPI::Generator::Serializable

  def initialize(@name); end

  @[OpenAPI::Field(type: String, example: "Robert")]
  property name : String
end

class Edge
  extend OpenAPI::Generator::Serializable

  def initialize(@name); end

  @[OpenAPI::Field(type: String, example: "Robert")]
  property name : String
end

class Driver
  extend OpenAPI::Generator::Serializable

  def initialize(@name); end

  @[OpenAPI::Field(type: String, example: "Robert")]
  property name : String
end

class Domain
  extend OpenAPI::Generator::Serializable

  def initialize(@name); end

  @[OpenAPI::Field(type: String, example: "Robert")]
  property name : String
end

class Broker
  extend OpenAPI::Generator::Serializable

  def initialize(@name); end

  @[OpenAPI::Field(type: String, example: "Robert")]
  property name : String
end

class Trigger
  extend OpenAPI::Generator::Serializable

  def initialize(@name, @description); end

  @[OpenAPI::Field(type: String, example: "Trigger #{Random.new.rand(5000)}")]
  property name : String
  @[OpenAPI::Field(type: String, example: "Trigger for zone 34")]
  property description : String
end

# Produces an OpenAPI::Schema reference.
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
