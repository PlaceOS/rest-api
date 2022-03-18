class PlaceOS::Driver; end

require "placeos-models"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"
require "openapi-generator/providers/action-controller"
require "openapi-generator/serializable"
require "openapi-generator/serializable/adapters/active-model"

require "./placeos-rest-api"

# Produces an OpenAPI::Schema reference.
macro finished
  OpenAPI::Generator::Helpers::ActionController.bootstrap

  OpenAPI::Generator.generate(
    OpenAPI::Generator::RoutesProvider::ActionController.new,
    options: {
      output: Path[Dir.current] / "openapi4.yml",
    },
    base_document: {
      info:       {
        title: "PlaceOS RestAPI",
        version: PlaceOS::Api::VERSION,
      },
      components: {
        security_schemes: {
          "bearerAuth" => OpenAPI::SecurityScheme.new(
            type: "http",
            scheme: "bearer",
            bearer_format: "JWT",
          ),
        },
      },
    }
  )
end
