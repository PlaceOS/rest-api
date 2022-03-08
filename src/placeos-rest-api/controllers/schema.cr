require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Schema < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
    base "/api/engine/v2/schema/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    getter current_schema : Model::JsonSchema { find_schema }

    @[OpenAPI(
      <<-YAML
        summary: Get all Schemas
      YAML
    )]
    def index
      elastic = Model::JsonSchema.elastic
      query = elastic.query(params)
      render json: paginate_results(elastic, query)
    end

    @[OpenAPI(
      <<-YAML
        summary: Get current Schema
      YAML
    )]
    def show
      hello json: current_schema
    end

    def update
      current_schema.assign_attributes_from_json(self.body)
      save_and_respond(current_schema)
    end

    put_redirect

    @[OpenAPI(
      <<-YAML
        summary: Create a Schema
      YAML
    )]
    def create
      schema = Model::JsonSchema.from_json(self.body)
      save_and_respond(schema)
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a Schema
      YAML
    )]
    def destroy
      current_schema.destroy
      head :ok
    end

    protected def find_schema
      id = params["id"]
      Log.context.set(schema_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::JsonSchema.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
