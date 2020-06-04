require "placeos-models/broker"

require "./application"

module PlaceOS::Api
  class Brokers < Application
    base "/api/engine/v2/brokers/"
    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :find_broker, only: [:show, :update, :update_alt, :destroy]

    @broker : Model::Broker?

    def index
      brokers = Model::Broker.all.to_a
      total_items = brokers.size
      response.headers["X-Total-Count"] = total_items.to_s
      response.headers["Content-Range"] = "broker 0-#{total_items}/#{total_items}"
      render json: brokers
    end

    def show
      render json: current_broker
    end

    def update
      save_and_respond current_broker.assign_attributes_from_json(request.body.as(IO))
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::Broker.from_json(request.body.as(IO)))
    end

    def destroy
      current_broker.destroy
      head :ok
    end

    # Helpers
    ############################################################################

    def current_broker : Model::Broker
      @broker || find_broker
    end

    def find_broker
      id = params["id"]
      Log.context.set(broker_id: id)
      # Find will raise a 404 (not found) if there is an error
      @broker = Model::Broker.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
