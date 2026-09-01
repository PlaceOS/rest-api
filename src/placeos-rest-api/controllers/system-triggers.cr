require "./application"

module PlaceOS::Api
  class SystemTriggers < Application
    include Utils::Permissions
    include Utils::GroupPermissions

    base "/api/engine/v2/systems/:sys_id/triggers/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    # Permissions
    ###############################################################################################

    # A trigger instance inherits the zones of its parent control system.
    # Reads need Read; mutations need the verb's bit (admin/support JWT and
    # the legacy org_zone path bypass as usual).
    @[AC::Route::Filter(:before_action, only: [:index, :show])]
    def check_trigger_read_permissions(sys_id : String)
      zones = ::PlaceOS::Model::ControlSystem.find!(sys_id).zones
      ensure_support_access!(zones, ::PlaceOS::Model::Permissions::Read)
      @secret_visible = secret_visible_on?(zones)
    end

    @[AC::Route::Filter(:before_action, only: [:create, :update, :destroy])]
    def check_trigger_write_permissions(sys_id : String)
      zones = ::PlaceOS::Model::ControlSystem.find!(sys_id).zones
      ensure_support_access!(zones, verb_permission)
      @secret_visible = secret_visible_on?(zones)
    end

    # `webhook_secret` is exposed to admin / support JWTs and to "support"
    # subsystem users holding Read (or Manage) on the system's zones —
    # everyone else (e.g. legacy org_zone managers, write-only grants) has it
    # stripped from responses.
    getter? secret_visible : Bool = false

    private def secret_visible_on?(zones : Array(String)) : Bool
      user_support? || support_subsystem_grants?(zones, ::PlaceOS::Model::Permissions::Read)
    end

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_sys_trig(
      @[AC::Param::Info(name: "trig_id", description: "the id of the trigger", example: "trig-1234")]
      id : String,
      @[AC::Param::Info(description: "the id of the system", example: "sys-1234")]
      sys_id : String,
    )
      Log.context.set(trigger_instance_id: id)
      # Find will raise a 404 (not found) if there is an error
      trig = ::PlaceOS::Model::TriggerInstance.find!(id)
      # The permission filters authorise the path's system, so the trigger
      # instance must actually belong to it — 404 (not 403) so ids from other
      # systems are indistinguishable from unknown ones.
      raise Error::NotFound.new("no trigger #{id} in system #{sys_id}") unless trig.control_system_id == sys_id
      @current_sys_trig = trig
    end

    getter! current_sys_trig : ::PlaceOS::Model::TriggerInstance

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_system(
      @[AC::Param::Info(description: "the id of the system", example: "sys-1234")]
      sys_id : String,
    )
      Log.context.set(control_system_id: sys_id)
      # Find will raise a 404 (not found) if there is an error
      @current_system = ::PlaceOS::Model::ControlSystem.find!(sys_id)
    end

    getter! current_system : ::PlaceOS::Model::ControlSystem

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
      as_of : Int64? = nil,
    ) : Array(::PlaceOS::Model::TriggerInstance)
      # PG full-text search (PPT-2644)
      query = ::PlaceOS::Model::TriggerInstance.all

      # Filter by system ID
      query = query.where(control_system_id: control_system_id)

      # Filter by trigger ID
      if trigger_id
        query = query.where(trigger_id: trigger_id)
      end

      # That occurred before a particular time
      if as_of
        # as_of is epoch seconds; compare at second granularity (the ES
        # pipeline stored epoch-second integers, so lte was second-precise —
        # a naive <= would exclude rows with sub-second timestamps)
        query = query.where("updated_at < ?", Time.unix(as_of + 1))
      end

      # Filter by importance
      if important
        query = query.where(important: true)
      end

      # Filter by triggered
      if triggered
        query = query.where(triggered: true)
      end

      # A trigger instance has no searchable text of its own, so `q` matches
      # the text of the parent trigger (replacing the Elasticsearch
      # has_parent(Trigger) query — search a system's trigger instances by
      # the trigger's name / description)
      if tsq = search_tsquery
        query = query.where(
          %[EXISTS (SELECT 1 FROM "trigger" t WHERE t.id = trig.trigger_id AND t.search_vector @@ to_tsquery('simple', ?))],
          tsq
        )
      end

      # no name column on this table — order by creation for determinism
      trigger_instances = paginate_sql(
        query.order("created_at, id"),
        ::PlaceOS::Model::TriggerInstance.table_name,
        limit: search_limit,
        offset: search_offset,
      ).map { |t| render_system_trigger(t, complete: complete) }
      trigger_instances
    end

    # return a particular trigger instance
    @[AC::Route::GET("/:trig_id")]
    def show(complete : Bool = true) : ::PlaceOS::Model::TriggerInstance
      # Default to render extra association fields
      render_system_trigger(current_sys_trig, complete: complete)
    end

    record UpdateParams, enabled : Bool?, important : Bool?, exec_enabled : Bool?, playlists : Array(String)? do
      include JSON::Serializable
    end

    # update the details of a trigger instance
    @[AC::Route::PATCH("/:trig_id", body: :args)]
    @[AC::Route::PUT("/:trig_id", body: :args)]
    def update(args : UpdateParams) : ::PlaceOS::Model::TriggerInstance
      current = current_sys_trig
      current.enabled = args.enabled.as(Bool) unless args.enabled.nil?
      current.important = args.important.as(Bool) unless args.important.nil?
      current.exec_enabled = args.exec_enabled.as(Bool) unless args.exec_enabled.nil?
      # validate the playlist ids
      if playlists = args.playlists
        if playlists.empty?
          current.playlists = playlists
        else
          current.playlists = ::PlaceOS::Model::Playlist.find_all(playlists).map(&.id.as(String))
        end
      end
      raise Error::ModelValidation.new(current.errors) unless current.save
      render_system_trigger(current)
    end

    # add a trigger to a system
    @[AC::Route::POST("/", body: :trig_inst, status_code: HTTP::Status::CREATED)]
    def create(
      trig_inst : ::PlaceOS::Model::TriggerInstance,
      @[AC::Param::Info(description: "the id of the system", example: "sys-1234")]
      sys_id : String,
    ) : ::PlaceOS::Model::TriggerInstance
      trig_inst.control_system_id = sys_id
      if (playlists = trig_inst.playlists) && !playlists.empty?
        trig_inst.playlists = ::PlaceOS::Model::Playlist.find_all(playlists).map(&.id.as(String))
      end
      raise Error::ModelValidation.new(trig_inst.errors) unless trig_inst.save
      render_system_trigger(trig_inst)
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
    class ::PlaceOS::Model::TriggerInstance
      property name : String? = nil
      @[JSON::Field(key: "control_system")]
      property control_system_details : Api::SystemTriggers::ControlSystemDetails? = nil

      def hide_secret
        @webhook_secret = nil
      end
    end

    # Render a TriggerInstance
    # - excludes `webhook_secret` unless the caller is admin / support or a
    #   "support" subsystem user with Read on the system's zones (see
    #   `secret_visible`, computed by the permission filters)
    # - includes `name`, `id` of parent ControlSystem, and `name` of if `complete = true`
    def render_system_trigger(trigger_instance : ::PlaceOS::Model::TriggerInstance, complete : Bool = false)
      if complete && (cs = trigger_instance.control_system)
        trigger_instance.control_system_details = ControlSystemDetails.new(cs.name.as(String), cs.id.as(String))
      end
      trigger_instance.name = trigger_instance.trigger.try &.name
      trigger_instance.hide_secret unless secret_visible?
      trigger_instance
    end
  end
end
