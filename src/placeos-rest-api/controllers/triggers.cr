require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Triggers < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
    base "/api/engine/v2/triggers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :current_trigger, only: [:show, :update, :update_alt, :destroy]
    before_action :ensure_json, only: [:create, :update, :update_alt]
    before_action :body, only: [:create, :update, :update_alt]

    ###############################################################################################

    getter current_trigger : Model::Trigger { find_trigger }

    @[OpenAPI(
      <<-YAML
        summary: get all triggers
        security:
        - bearerAuth: []
      YAML
    )]
    def index
      elastic = Model::Trigger.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      render json: paginate_results(elastic, query), type: Array(Model::Trigger)
    end

    @[OpenAPI(
      <<-YAML
        summary: get a trigger
        security:
        - bearerAuth: []
      YAML
    )]
    def show
      include_instances = param(instances : Bool?, description: "Include instances data in response")
      render json: !include_instances ? current_trigger : with_fields(current_trigger, {
        :trigger_instances => current_trigger.trigger_instances.to_a,
      }), type: Model::Trigger
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a trigger
        security:
        - bearerAuth: []
      YAML
    )]
    def update
      updated_trigger = current_trigger.assign_attributes_from_json(body_raw Model::Trigger)
      save_and_respond(updated_trigger)
    end

    put_redirect

    @[OpenAPI(
      <<-YAML
        summary: Create a trigger
        security:
        - bearerAuth: []
      YAML
    )]
    def create
      trigger = body_as Model::Trigger, constructor: :from_json
      save_and_respond(trigger)
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a trigger
        security:
        - bearerAuth: []
      YAML
    )]
    def destroy
      current_trigger.destroy # expires the cache in after callback
      head :ok
    end

    # Get instances associated with

    get("/:id/instances", :instances, annotations: @[OpenAPI(<<-YAML
    summary: Get list of instances associated wtih given id of users based on email
    security:
    - bearerAuth: []
    YAML
    )]) do
      instances = current_trigger.trigger_instances.to_a

      set_collection_headers(instances.size, Model::TriggerInstance.table_name)

      render json: instances, type: Array(Model::TriggerInstance)
    end

    # Helpers
    ###########################################################################

    protected def find_trigger
      id = params["id"]
      Log.context.set(trigger_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Trigger.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
