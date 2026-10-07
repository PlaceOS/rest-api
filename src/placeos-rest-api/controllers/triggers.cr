require "./application"

module PlaceOS::Api
  # Triggers, automation rules that run actions when conditions on system state are met
  class Triggers < Application
    base "/api/engine/v2/triggers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :instances]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, only: [:create, :update, :destroy]
    # `instances` exposes every system using a trigger (including each
    # instance's webhook_secret) so it is support/admin only, like show.
    before_action :check_support, only: [:index, :show, :instances]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_trigger(id : String)
      Log.context.set(trigger_id: id)
      # Find will raise a 404 (not found) if there is an error
      trigger = ::PlaceOS::Model::Trigger.find!(id)
      # a trigger bound to a system follows that system; a definition with
      # no system is a template any organisation may instantiate
      ensure_reach!(trigger) if trigger.control_system_id
      @current_trigger = trigger
    end

    # Templates are cluster-managed
    @[AC::Route::Filter(:before_action, only: [:update, :destroy])]
    def check_template_write
      check_cluster_admin if current_trigger.control_system_id.nil?
    end

    getter! current_trigger : ::PlaceOS::Model::Trigger

    ###############################################################################################

    # returns the list of available triggers
    @[AC::Route::GET("/")]
    def index : Array(::PlaceOS::Model::Trigger)
      # PG full-text search (PPT-2644)
      query = ::PlaceOS::Model::Trigger.all
      if ids = tenancy.organisation_ids
        list = ids.to_a.map(&.to_s)
        query = if list.empty?
                  query.where("control_system_id IS NULL", [] of String)
                else
                  query.where("(control_system_id IS NULL OR organisation_id = ANY(ARRAY[#{list.join(", ") { "?" }}]::uuid[]))", list)
                end
      end
      paginate_search(query, ::PlaceOS::Model::Trigger.table_name)
    end

    # update so we can provide instance details
    class ::PlaceOS::Model::Trigger
      @[JSON::Field(key: "trigger_instances")]
      property trigger_instances_details : Array(::PlaceOS::Model::TriggerInstance)? = nil
    end

    # returns the details of a trigger
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "instances", description: "return the instances associated with this trigger", example: "true")]
      include_instances : Bool? = nil,
    ) : ::PlaceOS::Model::Trigger
      trig = current_trigger
      trig.trigger_instances_details = trig.trigger_instances.to_a if include_instances
      trig
    end

    # updates a trigger details
    @[AC::Route::PATCH("/:id", body: :trig)]
    @[AC::Route::PUT("/:id", body: :trig)]
    def update(trig : ::PlaceOS::Model::Trigger) : ::PlaceOS::Model::Trigger
      current = current_trigger
      current.assign_attributes(trig)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new trigger
    @[AC::Route::POST("/", body: :trig, status_code: HTTP::Status::CREATED)]
    def create(trig : ::PlaceOS::Model::Trigger) : ::PlaceOS::Model::Trigger
      if cs_id = trig.control_system_id
        system = ::PlaceOS::Model::ControlSystem.find!(cs_id)
        ensure_reach!(system)
        trig.organisation_id = system.organisation_id
      else
        check_cluster_admin
      end
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
    def instances : Array(::PlaceOS::Model::TriggerInstance)
      instances = current_trigger.trigger_instances.to_a
      set_collection_headers(instances.size, ::PlaceOS::Model::TriggerInstance.table_name)
      instances
    end
  end
end
