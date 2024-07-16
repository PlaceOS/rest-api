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
      @current_broker = ::PlaceOS::Model::Broker.find!(id)
    end

    getter! current_broker : ::PlaceOS::Model::Broker

    ###############################################################################################

    # returns the list of MQTT brokers receiving state information
    @[AC::Route::GET("/")]
    def collection : Array(::PlaceOS::Model::Broker)
      # named collection, not index as we don't support query params on this route
      brokers = ::PlaceOS::Model::Broker.all.to_a
      set_collection_headers(brokers.size, ::PlaceOS::Model::Broker.table_name)
      brokers
    end

    # returns the details of the selected broker
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Broker
      current_broker
    end

    # updates the details of a broker
    @[AC::Route::PATCH("/:id", body: :broker)]
    @[AC::Route::PUT("/:id", body: :broker)]
    def update(broker : ::PlaceOS::Model::Broker) : ::PlaceOS::Model::Broker
      current = current_broker
      current.assign_attributes(broker)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new broker
    @[AC::Route::POST("/", body: :broker, status_code: HTTP::Status::CREATED)]
    def create(broker : ::PlaceOS::Model::Broker) : ::PlaceOS::Model::Broker
      raise Error::ModelValidation.new(broker.errors) unless broker.save
      broker
    end

    # removes a broker
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_broker.destroy
    end
  end
end
