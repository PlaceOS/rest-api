require "placeos-models/broker"

require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Brokers < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
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
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array Broker}
      YAML
    )]
    def index
      brokers = Model::Broker.all.to_a

      set_collection_headers(brokers.size, Model::Broker.table_name)

      render json: brokers
    end

    @[OpenAPI(
      <<-YAML
        summary: get current broker
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Broker}
      YAML
    )]
    def show
      render json: current_broker
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a broker
        requestBody:
          required: true
          content:
            #{Schema.ref Broker}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Broker}
      YAML
    )]
    def update
      save_and_respond current_broker.assign_attributes_from_json(self.body)
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put("/:id", :update_alt, annotations: @[OpenAPI(<<-YAML
      summary: Update a trigger
      requestBody:
        required: true
        content:
          #{Schema.ref Broker}
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
          content:
            #{Schema.ref Broker}
      YAML
    )]) { update }

    @[OpenAPI(
      <<-YAML
        summary: Create a broker
        requestBody:
          required: true
          content:
            #{Schema.ref Broker}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref Broker}
      YAML
    )]
    def create
      save_and_respond(Model::Broker.from_json(self.body))
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a broker
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
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
