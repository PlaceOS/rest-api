require "promise"

require "./application"

module PlaceOS::Api
  class Zones < Application
    include Utils::CoreHelper

    base "/api/engine/v2/zones/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, except: [:index]

    # Response helpers
    ###############################################################################################

    # extend the Zone model for the show function
    class Model::Zone
      @[JSON::Field(key: "trigger_data")]
      property trigger_data_details : Array(Model::Trigger)? = nil
    end

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :metadata])]
    def current_zone(id : String)
      Log.context.set(zone_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_zone = Model::Zone.find!(id)
    end

    getter! current_zone : Model::Zone

    ###############################################################################################

    # list the configured zones
    @[AC::Route::GET("/", converters: {tags: ConvertStringArray})]
    def index(
      @[AC::Param::Info(description: "only return zones who have this zone as a parent", example: "zone-1234")]
      parent_id : String? = nil,
      @[AC::Param::Info(description: "return zones with particular tags", example: "building,level")]
      tags : Array(String)? = nil
    ) : Array(Model::Zone)
      elastic = Model::Zone.elastic
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

    # return the details of the zone
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(description: "also return any triggers associated with the zone", example: "true")]
      complete : Bool = false
    ) : Model::Zone
      # Include trigger data in response
      current_zone.trigger_data_details = current_zone.trigger_data if complete
      current_zone
    end

    # update the details of a zone
    @[AC::Route::PATCH("/:id", body: :zone)]
    @[AC::Route::PUT("/:id", body: :zone)]
    def update(zone : Model::Zone) : Model::Zone
      current = current_zone
      current.assign_attributes(zone)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new zone
    @[AC::Route::POST("/", body: :zone, status_code: HTTP::Status::CREATED)]
    def create(zone : Model::Zone) : Model::Zone
      raise Error::ModelValidation.new(zone.errors) unless zone.save
      zone
    end

    # remove a zone and any children zones
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      zone_id = current_zone.id
      current_zone.destroy
      spawn { Api::Metadata.signal_metadata(:destroy_all, {parent_id: zone_id}) }
    end

    # return metadata associcated with the selected zone
    @[AC::Route::GET("/:id/metadata")]
    def metadata(
      id : String,
      @[AC::Param::Info(description: "only return the metadata key we are interested in", example: "workplace-config")]
      name : String? = nil
    ) : Hash(String, PlaceOS::Model::Metadata::Interface)
      Model::Metadata.build_metadata(id, name)
    end

    private enum ExecStatus
      Success
      Failure
      Missing
    end

    # Return triggers attached to current zone
    @[AC::Route::GET("/:id/triggers")]
    def trigger_instances : Array(Model::Trigger)
      triggers = current_zone.trigger_data
      set_collection_headers(triggers.size, Model::Trigger.table_name)
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
      method : String
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
            Model::Module.find!(module_id).edge_id.as(String)
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
