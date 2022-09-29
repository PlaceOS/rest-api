require "./application"

module PlaceOS::Api
  class SystemTriggers < Application
    base "/api/engine/v2/systems/:sys_id/triggers/"
    id_param :trig_id

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_sys_trig(
      @[AC::Param::Info(name: "trig_id", description: "the id of the trigger", example: "trig-1234")]
      id : String
    )
      Log.context.set(trigger_instance_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_sys_trig = Model::TriggerInstance.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_sys_trig : Model::TriggerInstance

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_system(
      @[AC::Param::Info(description: "the id of the system", example: "sys-1234")]
      sys_id : String
    )
      Log.context.set(control_system_id: sys_id)
      # Find will raise a 404 (not found) if there is an error
      @current_system = Model::ControlSystem.find!(sys_id, runopts: {"read_mode" => "majority"})
    end

    getter! current_system : Model::ControlSystem

    ###############################################################################################

    # return the list of triggers associated with the system specified
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(name: "sys_id", description: "the system to filter on", example: "sys-1234")]
      control_system_id : String,
      @[AC::Param::Info(description: "provide the control system details?", example: "false")]
      complete : Bool = true,
      @[AC::Param::Info(description: "only return triggers marked as important?", example: "true")]
      important : Bool = false,
      @[AC::Param::Info(description: "only return triggers that have recently been triggered?", example: "true")]
      triggered : Bool = false,
      @[AC::Param::Info(description: "filter by a particular trigger type", example: "trig-1234")]
      trigger_id : String? = nil,
      @[AC::Param::Info(description: "return triggers updated before the time specified, unix epoch", example: "123456")]
      as_of : Int64? = nil
    ) : Array(Model::TriggerInstance)
      elastic = Model::TriggerInstance.elastic
      query = elastic.query(search_params)

      # Filter by system ID
      query.must({"control_system_id" => [control_system_id]})

      # Filter by trigger ID
      if trigger_id
        query.filter({"trigger_id" => [trigger_id]})
      end

      # That occurred before a particular time
      if as_of
        query.range({
          "updated_at" => {
            :lte => as_of,
          },
        })
      end

      # Filter by importance
      if important
        query.filter({"important" => [true]})
      end

      # Filter by triggered
      if triggered
        query.filter({"triggered" => [true]})
      end

      # Include parent documents in the search
      query.has_parent(parent: Model::Trigger, parent_index: Model::Trigger.table_name)

      trigger_instances = paginate_results(elastic, query).map { |t| render_system_trigger(t, complete: complete) }
      trigger_instances
    end

    # return a particular trigger instance
    @[AC::Route::GET("/:trig_id")]
    def show(complete : Bool = true) : Model::TriggerInstance
      # Default to render extra association fields
      render_system_trigger(current_sys_trig, complete: complete)
    end

    record UpdateParams, enabled : Bool?, important : Bool?, exec_enabled : Bool? do
      include JSON::Serializable
    end

    # update the details of a trigger instance
    @[AC::Route::PATCH("/:trig_id", body: :args)]
    @[AC::Route::PUT("/:trig_id", body: :args)]
    def update(args : UpdateParams) : Model::TriggerInstance
      current = current_sys_trig
      current.enabled = args.enabled.as(Bool) unless args.enabled.nil?
      current.important = args.important.as(Bool) unless args.important.nil?
      current.exec_enabled = args.exec_enabled.as(Bool) unless args.exec_enabled.nil?
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a trigger to a system
    @[AC::Route::POST("/", body: :trig_inst, status_code: HTTP::Status::CREATED)]
    def create(
      trig_inst : Model::TriggerInstance,
      @[AC::Param::Info(description: "the id of the system", example: "sys-1234")]
      sys_id : String
    ) : Model::TriggerInstance
      trig_inst.control_system_id = sys_id
      raise Error::ModelValidation.new(trig_inst.errors) unless trig_inst.save
      trig_inst
    end

    # remove a trigger from a system
    @[AC::Route::DELETE("/:trig_id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_sys_trig.destroy # Expires the cache in after callback
    end

    # Helpers
    ###########################################################################

    record ControlSystemDetails, name : String, id : String do
      include JSON::Serializable
    end

    # extend the ControlSystem model to handle our return values
    class Model::TriggerInstance
      property name : String? = nil
      @[JSON::Field(key: "control_system")]
      property control_system_details : Api::SystemTriggers::ControlSystemDetails? = nil

      def hide_secret
        @webhook_secret = nil
      end
    end

    # Render a TriggerInstance
    # - excludes `webhook_secret` if authorized user has a support role (or lower)
    # - includes `name`, `id` of parent ControlSystem, and `name` of if `complete = true`
    def render_system_trigger(trigger_instance : Model::TriggerInstance, complete : Bool = false)
      if complete && (cs = trigger_instance.control_system)
        trigger_instance.control_system_details = ControlSystemDetails.new(cs.name.as(String), cs.id.as(String))
      end
      trigger_instance.name = trigger_instance.trigger.try &.name
      trigger_instance.hide_secret unless is_admin?
      trigger_instance
    end
  end
end
