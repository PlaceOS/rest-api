require "placeos-models/broker"

require "./application"

module PlaceOS::Api
  class Brokers < Application
    base "/api/engine/v2/brokers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:collection, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:collection, :show]
    before_action :check_support, only: [:collection, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:collection, :create])]
    def find_current_broker(id : String)
      Log.context.set(broker_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_broker = Model::Broker.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_broker : Model::Broker

    ###############################################################################################

    @[AC::Route::GET("/")]
    def collection : Array(Model::Broker)
      # named collection, not index as we don't support query params on this route
      brokers = Model::Broker.all.to_a
      set_collection_headers(brokers.size, Model::Broker.table_name)
      brokers
    end

    @[AC::Route::GET("/:id")]
    def show : Model::Broker
      current_broker
    end

    @[AC::Route::PATCH("/:id", body: :broker)]
    @[AC::Route::PUT("/:id", body: :broker)]
    def update(broker : Model::Broker) : Model::Broker
      current = current_broker
      current.assign_attributes(broker)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    @[AC::Route::POST("/", body: :broker, status_code: HTTP::Status::CREATED)]
    def create(broker : Model::Broker) : Model::Broker
      raise Error::ModelValidation.new(broker.errors) unless broker.save
      broker
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_broker.destroy
    end
  end
end
