require "promise"

require "./application"

module ACAEngine::Api
  class Zones < Application
    include Utils::CoreHelper
    base "/api/engine/v2/zones/"

    before_action :check_admin, except: [:index]
    before_action :check_support, except: [:index]
    before_action :find_zone, only: [:show, :update, :destroy]

    @zone : Model::Zone?
    getter :zone

    def index
      elastic = Model::Zone.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      if params.has_key? "tags"
        # list of unique tags
        tags = params["tags"].gsub(/[^0-9a-z ]/i, "").split(/\s+/).reject(&.empty?).uniq

        head :bad_request if tags.empty?

        query.must({
          "tags" => tags,
        })
      else
        head :forbidden unless is_support? || is_admin?

        query.search_field "name"
      end

      render json: elastic.search(query)
    end

    # BREAKING CHANGE: param key `data` used to attempt to retrieve a setting from the zone
    def show
      if params.has_key? "complete"
        # Include trigger data in response
        render json: with_fields(current_zone, {
          :trigger_data => current_zone.trigger_data,
        })
      else
        render json: current_zone
      end
    end

    def update
      current_zone.assign_attributes_from_json(request.body.as(IO))
      save_and_respond current_zone
    end

    def create
      save_and_respond Model::Zone.from_json(request.body.as(IO))
    end

    def destroy
      current_zone.destroy
      head :ok
    end

    private enum ExecStatus
      Success
      Failure
      Missing
    end

    # Execute a method on a module across all systems in a Zone
    post("/:id/exec/:module_slug/:method") do
      zone_id, module_slug, method = params["id"], params["module_slug"], params["method"]
      args = Array(JSON::Any).from_json(request.body.as(IO))
      module_name, index = Driver::Proxy.get_parts(module_slug)

      # TODO: Promise callback renders external values nillable?
      # execute_results = Promise.map(current_zone.systems) do |system|
      execute_results = current_zone.systems.map do |system|
        system_id = system.id.as(String)
        remote_driver = Driver::Proxy::RemoteDriver.new(
          sys_id: system_id,
          module_name: module_name.as(String),
          index: index.as(Int32)
        )

        response = remote_driver.exec(
          security: driver_clearance(user_token),
          function: method.as(String),
          args: args.as(Array(JSON::Any)),
          request_id: logger.request_id.as(String),
        )

        logger.tag_debug(
          message: "successful module exec",
          system_id: system_id,
          module_name: module_name,
          index: index,
          method: method,
          output: response
        )

        {system_id.as(String), ExecStatus::Success}
      rescue e : Driver::Proxy::RemoteDriver::Error
        driver_execute_error_response(e, respond: false)
        if e.error_code == Driver::Proxy::RemoteDriver::ErrorCode::ModuleNotFound
          {system_id.as(String), ExecStatus::Missing}
        else
          {system_id.as(String), ExecStatus::Failure}
        end
      end

      response = {success: [] of String, failure: [] of String, module_missing: [] of String}
      execute_results.each do |system_id, status|
        key = case status
              when ExecStatus::Success then :success
              when ExecStatus::Failure then :failures
              when ExecStatus::Missing then :module_missing
              end.as(Symbol) # TODO: remove once merged https://github.com/crystal-lang/crystal/pull/8424
        response[key] << system_id
      end

      render json: response
    rescue e : Driver::Proxy::RemoteDriver::Error
      driver_execute_error_response(e)
    rescue e
      logger.tag_error(
        message: "core execute request failed",
        error: e.message,
        zone_id: zone_id,
        module_name: module_name,
        index: index,
        method: method,
        backtrace: e.inspect_with_backtrace,
      )
      render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
    end

    # Helpers
    ###########################################################################

    def current_zone : Model::Zone
      return @zone.as(Model::Zone) if @zone
      find_zone
    end

    def find_zone
      # Find will raise a 404 (not found) if there is an error
      @zone = Model::Zone.find!(params["id"]?)
    end
  end
end
