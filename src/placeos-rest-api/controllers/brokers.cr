require "placeos-models/broker"

require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Brokers < Application
    base "/api/engine/v2/brokers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :current_broker, only: [:show, :update, :update_alt, :destroy]
    before_action :body, only: [:create, :update, :update_alt]

    ###############################################################################################

    getter current_broker : Model::Broker { find_broker }

    @[OpenAPI(
      <<-YAML
        summary: get all brokers
        security:
        - bearerAuth: []
      YAML
    )]
    def index
      brokers = Model::Broker.all.to_a

      set_collection_headers(brokers.size, Model::Broker.table_name)

      render json: brokers, type: Array(Model::Broker)
    end

    @[OpenAPI(
      <<-YAML
        summary: get current broker
        security:
        - bearerAuth: []
      YAML
    )]
    def show
      render json: current_broker, type: Model::Broker
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a broker
        security:
        - bearerAuth: []
      YAML
    )]
    def update
      save_and_respond current_broker.assign_attributes_from_json(body_raw Model::Broker)
    end

    put_redirect

    @[OpenAPI(
      <<-YAML
        summary: Create a broker
        security:
        - bearerAuth: []
      YAML
    )]
    def create
      broker = body_as Model::Broker, constructor: :from_json
      save_and_respond(broker)
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a broker
        security:
        - bearerAuth: []
      YAML
    )]
    def destroy
      current_broker.destroy
      head :ok
    end

    # Helpers
    ############################################################################

    protected def find_broker
      id = params["id"]
      Log.context.set(broker_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Broker.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
