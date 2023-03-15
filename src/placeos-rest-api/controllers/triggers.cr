require "./application"

module PlaceOS::Api
  class Triggers < Application
    base "/api/engine/v2/triggers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_trigger(id : String)
      Log.context.set(trigger_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_trigger = Model::Trigger.find!(id)
    end

    getter! current_trigger : Model::Trigger

    ###############################################################################################

    # returns the list of available triggers
    @[AC::Route::GET("/")]
    def index : Array(Model::Trigger)
      elastic = Model::Trigger.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # update so we can provide instance details
    class Model::Trigger
      @[JSON::Field(key: "trigger_instances")]
      property trigger_instances_details : Array(Model::TriggerInstance)? = nil
    end

    # returns the details of a trigger
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "instances", description: "return the instances associated with this trigger", example: "true")]
      include_instances : Bool? = nil
    ) : Model::Trigger
      trig = current_trigger
      trig.trigger_instances_details = trig.trigger_instances.to_a if include_instances
      trig
    end

    # updates a trigger details
    @[AC::Route::PATCH("/:id", body: :trig)]
    @[AC::Route::PUT("/:id", body: :trig)]
    def update(trig : Model::Trigger) : Model::Trigger
      current = current_trigger
      current.assign_attributes(trig)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new trigger
    @[AC::Route::POST("/", body: :trig, status_code: HTTP::Status::CREATED)]
    def create(trig : Model::Trigger) : Model::Trigger
      raise Error::ModelValidation.new(trig.errors) unless trig.save
      trig
    end

    # removes a trigger
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_trigger.destroy # expires the cache in after callback
    end

    # Get instances of a trigger, how many systems are using a trigger
    @[AC::Route::GET("/:id/instances")]
    def instances : Array(Model::TriggerInstance)
      instances = current_trigger.trigger_instances.to_a
      set_collection_headers(instances.size, Model::TriggerInstance.table_name)
      instances
    end
  end
end
