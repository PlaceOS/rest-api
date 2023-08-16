require "./application"

module PlaceOS::Api
  class Settings < Application
    include Utils::Permissions

    base "/api/engine/v2/settings/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :history]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    # permissions are checked as part of the route
    before_action :check_admin, except: [:index, :show, :create, :update]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_settings(id : String)
      Log.context.set(settings_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_settings = Model::Settings.find!(id)
    end

    getter! current_settings : Model::Settings

    # Permissions
    ###############################################################################################

    def can_view?(parent_id)
      return if user_support?
      check_access_level(parent_id, admin_required: false)
    end

    def can_modify?(setting)
      return if user_admin?
      raise Error::Forbidden.new("can only modify unencrypted settings") unless setting.encryption_level.none?
      parent_id = setting.parent_id.as(String)
      check_access_level(parent_id, admin_required: true)
    end

    def check_access_level(parent_id : String, admin_required : Bool)
      # find the org zone
      authority = current_authority.as(Model::Authority)
      org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id

      access = Permission::None

      # check if the user has access
      case parent_id
      when .starts_with?(Model::ControlSystem.table_name)
        zones = Model::ControlSystem.find!(parent_id).zones
        if zones.includes? org_zone_id
          access = check_access(current_user.groups, zones)
        end
      when .starts_with?(Model::Module.table_name)
        # NOTE:: duplicate of Modules#can_modify?
        mod = Model::Module.find!(parent_id)
        cs_id = mod.control_system_id
        raise Error::Forbidden.new unless cs_id

        zones = Model::ControlSystem.find!(cs_id).zones
        raise Error::Forbidden.new unless zones.includes?(org_zone_id)
        access = check_access(current_user.groups, zones)
      when .starts_with?(Model::Zone.table_name)
        zone = Model::Zone.find!(parent_id)
        root_zone_id = zone.root_zone_id

        if root_zone_id == org_zone_id
          zones = [org_zone_id, zone.id].compact.uniq!
          access = check_access(current_user.groups, zones)
        end
      end

      raise Error::Forbidden.new unless admin_required ? access.admin? : access.manage?
    end

    ###############################################################################################

    # list the settings associated with the provided parent object
    @[AC::Route::GET("/", converters: {parent_id: ConvertStringArray})]
    def index(
      parent_id : Array(String)? = nil
    ) : Array(Model::Settings)
      if parents = parent_id
        parents.each { |pid| can_view?(pid) }

        # Directly search for model's settings
        parent_settings = Model::Settings.for_parent(parents)
        # Decrypt for the user
        parent_settings.each &.decrypt_for!(current_user)
        parent_settings
      else
        raise Error::Forbidden.new unless user_support?

        elastic = Model::Settings.elastic
        query = elastic.query(search_params)
        paginate_results(elastic, query)
      end
    end

    # return the requested setting details
    @[AC::Route::GET("/:id")]
    def show : Model::Settings
      can_view?(current_settings.parent_id.as(String))
      current_settings.decrypt_for!(current_user)
    end

    # udpate a setting
    @[AC::Route::PATCH("/:id", body: :setting)]
    @[AC::Route::PUT("/:id", body: :setting)]
    def update(setting : Model::Settings) : Model::Settings
      current = current_settings
      can_modify?(current)

      current.assign_attributes(setting)
      current.modified_by = current_user
      can_modify?(current)

      raise Error::ModelValidation.new(current.errors) unless current.save
      current.decrypt_for!(current_user)
    end

    # add a new setting
    @[AC::Route::POST("/", body: :setting, status_code: HTTP::Status::CREATED)]
    def create(setting : Model::Settings) : Model::Settings
      can_modify?(setting)
      setting.modified_by = current_user
      raise Error::ModelValidation.new(setting.errors) unless setting.save
      setting.decrypt_for!(current_user)
    end

    # remove a setting
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_settings.destroy
    end

    # Returns the version history for a Settings model
    @[AC::Route::GET("/:id/history")]
    def history(
      @[AC::Param::Info(description: "the maximum number of results to return", example: "10000")]
      limit : Int32 = 15,
      @[AC::Param::Info(description: "the starting offset of the result set. Used to implement pagination")]
      offset : Int32 = 0
    ) : Array(Model::Settings)
      history = current_settings.history(offset: offset, limit: limit).to_a

      total = current_settings.history_count
      range_start = offset
      range_end = history.size + range_start

      response.headers["X-Total-Count"] = total.to_s
      response.headers["Content-Range"] = "sets #{range_start}-#{range_end}/#{total}"

      # Set link
      if range_end < total
        query_params["offset"] = (range_end + 1).to_s
        query_params["limit"] = limit.to_s
        path = File.join(base_route, "/#{current_settings.id}/history")
        response.headers["Link"] = %(<#{path}?#{query_params}>; rel="next")
      end

      history
    end

    # Helpers
    ###########################################################################

    # Get an ordered hierarchy of Settings for the model
    #
    def self.collated_settings(user : Model::User, model : Model::ControlSystem | Model::Module)
      model
        .settings_hierarchy
        .reverse!
        .tap(&.each(&.decrypt_for!(user)))
    end
  end
end
