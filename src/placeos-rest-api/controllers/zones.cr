require "promise"

require "./application"

module PlaceOS::Api
  class Zones < Application
    include Utils::CoreHelper
    include Utils::Permissions

    base "/api/engine/v2/zones/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_support, only: [:zone_execute]

    # Response helpers
    ###############################################################################################

    # extend the Zone model for the show function
    class ::PlaceOS::Model::Zone
      @[JSON::Field(key: "trigger_data")]
      property trigger_data_details : Array(::PlaceOS::Model::Trigger)? = nil
    end

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :tags, :create, :metadata])]
    def current_zone(id : String)
      Log.context.set(zone_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_zone = ::PlaceOS::Model::Zone.find!(id)
    end

    getter! current_zone : ::PlaceOS::Model::Zone

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :zone_update)]
    def parse_update_zone(@zone_update : ::PlaceOS::Model::Zone)
    end

    getter! zone_update : ::PlaceOS::Model::Zone

    # Permissions
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:destroy])]
    def check_delete_permissions
      return if user_support?
      check_access_level(current_zone, admin_required: true)
    end

    @[AC::Route::Filter(:before_action, only: [:update])]
    def check_update_permissions
      return if user_support?
      check_access_level(current_zone, admin_required: false)
      if zone_update.parent_id != current_zone.parent_id
        check_access_level(zone_update, admin_required: false)
      end
    end

    @[AC::Route::Filter(:before_action, only: [:create])]
    def check_create_permissions
      return if user_support?
      check_access_level(zone_update, admin_required: false)
    end

    def check_access_level(zone : ::PlaceOS::Model::Zone, admin_required : Bool = false)
      # find the org zone
      authority = current_authority.as(::PlaceOS::Model::Authority)
      org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id
      raise Error::Forbidden.new unless zone.persisted? || zone.parent_id.presence

      root_zone_id = zone.root_zone_id

      # ensure the system is part of the organisation
      if root_zone_id == org_zone_id
        zones = [org_zone_id, zone.id].compact.uniq!
        access = check_access(current_user.groups, zones)

        if admin_required
          return if access.admin?
        else
          return if access.can_manage?
        end
      end

      raise Error::Forbidden.new
    end

    ###############################################################################################

    # list the configured zones
    @[AC::Route::GET("/", converters: {tags: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "only return zones who have this zone as a parent", example: "zone-1234")]
      parent_id : String? = nil,
      @[AC::Param::Info(description: "return zones with particular tags", example: "building,level")]
      tags : Array(String)? = nil,
    ) : Array(::PlaceOS::Model::Zone)
      elastic = ::PlaceOS::Model::Zone.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)

      # Limit results to the children of this parent
      if parent = parent_id
        query.must({
          "parent_id" => [parent],
        })
      end

      # Limit results to zones containing the passed list of tags
      if (filter_tags = tags) && !filter_tags.empty?
        query.must({
          "tags" => filter_tags,
        })
      else
        raise Error::Forbidden.new unless user_support?
        query.search_field "name"
      end

      paginate_results(elastic, query)
    end

    # returns unique zone tags
    @[AC::Route::GET("/tags")]
    def tags : Array(String)
      unique_tags = PgORM::Database.connection do |db|
        db.query_one "select string_agg(distinct tag, ', ' order by tag) as types from ( select unnest(tags) as tag from zone ) as unnested", &.read(String)
      end
      unique_tags.split(',')
    end

    # return the details of the zone
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(description: "also return any triggers associated with the zone", example: "true")]
      complete : Bool = false,
    ) : ::PlaceOS::Model::Zone
      # Include trigger data in response
      current_zone.trigger_data_details = current_zone.trigger_data if complete
      current_zone
    end

    # update the details of a zone
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::Zone
      zone = zone_update
      current = current_zone
      current.assign_attributes(zone)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new zone
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::Zone
      zone = zone_update
      raise Error::ModelValidation.new(zone.errors) unless zone.save
      zone
    end

    # remove a zone and any children zones
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      zone_id = current_zone.id
      current_zone.destroy
      spawn { Api::Metadata.signal_metadata(current_authority.not_nil!.id.to_s, :destroy_all, {parent_id: zone_id}) }
    end

    # return metadata associcated with the selected zone
    @[AC::Route::GET("/:id/metadata")]
    def metadata(
      id : String,
      @[AC::Param::Info(description: "only return the metadata key we are interested in", example: "workplace-config")]
      name : String? = nil,
    ) : Hash(String, ::PlaceOS::Model::Metadata::Interface)
      ::PlaceOS::Model::Metadata.build_metadata(id, name)
    end

    private enum ExecStatus
      Success
      Failure
      Missing
    end

    # Return triggers attached to current zone
    @[AC::Route::GET("/:id/triggers")]
    def trigger_instances : Array(::PlaceOS::Model::Trigger)
      triggers = current_zone.trigger_data
      set_collection_headers(triggers.size, ::PlaceOS::Model::Trigger.table_name)
      triggers
    end

    record(
      ZoneExecResponse,
      success : Array(String) = [] of String,
      failure : Array(String) = [] of String,
      module_missing : Array(String) = [] of String
    ) { include JSON::Serializable }

    # Execute a method on a module across all systems in a Zone
    @[AC::Route::POST("/:id/exec/:module_slug/:method", body: :args)]
    def zone_execute(
      args : Array(JSON::Any),
      id : String,
      @[AC::Param::Info(description: "the combined module class and index, index is optional and defaults to 1", example: "Display_2")]
      module_slug : String,
      @[AC::Param::Info(description: "the method to execute on the module", example: "power")]
      method : String,
    ) : ZoneExecResponse
      module_name, index = Driver::Proxy::RemoteDriver.get_parts(module_slug)

      results = Promise.map(current_zone.systems) do |system|
        system_id = system.id.as(String)
        Log.context.set(system_id: system_id, module_name: module_name, index: index)
        begin
          remote_driver = Driver::Proxy::RemoteDriver.new(
            sys_id: system_id,
            module_name: module_name,
            index: index
          ) { |module_id|
            ::PlaceOS::Model::Module.find!(module_id).edge_id.as(String)
          }

          output, status_code = remote_driver.exec(
            security: driver_clearance(user_token),
            function: method,
            args: args,
            request_id: request_id,
            user_id: current_user.id,
          )

          Log.debug { {message: "module exec success", method: method, status_code: status_code, output: output} }

          {system_id, ExecStatus::Success}
        rescue e : Driver::Proxy::RemoteDriver::Error
          handle_execute_error(e, respond: false)
          status = e.error_code.module_not_found? ? ExecStatus::Missing : ExecStatus::Failure
          {system_id, status}
        end
      end.get.not_nil!.to_a.compact

      results.each_with_object(ZoneExecResponse.new) do |(id, status), obj|
        case status
        in ExecStatus::Success then obj.success
        in ExecStatus::Failure then obj.failure
        in ExecStatus::Missing then obj.module_missing
        end << id
      end
    rescue e
      Log.error(exception: e) { {
        message:     "core execute request failed",
        zone_id:     id,
        module_name: module_name,
        index:       index,
        method:      method,
      } }
      raise e
    end
  end
end
