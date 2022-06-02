require "placeos-models/broker"

require "./application"

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

    getter current_broker : Model::Broker do
      id = params["id"]
      Log.context.set(broker_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Broker.find!(id, runopts: {"read_mode" => "majority"})
    end

    ###############################################################################################

    def index
      brokers = Model::Broker.all.to_a

      set_collection_headers(brokers.size, Model::Broker.table_name)

      render json: brokers
    end

    def show
      render json: current_broker
    end

    def update
      save_and_respond current_broker.assign_attributes_from_json(self.body)
    end

    put_redirect

    def create
      save_and_respond(Model::Broker.from_json(self.body))
    end

    def destroy
      current_broker.destroy
      head :ok
    end
  end
end
