require "promise"

require "./application"

module PlaceOS::Api
  class Zones < Application
    include Utils::CoreHelper
    base "/api/engine/v2/zones/"

    before_action :check_admin, except: [:index]
    before_action :check_support, except: [:index]
    before_action :find_zone, only: [:show, :update, :destroy]

    getter zone : Model::Zone?

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

      render json: paginate_results(elastic, query)
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

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id" { update }

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
      module_name, index = ::PlaceOS::Driver::Proxy::RemoteDriver.get_parts(module_slug)

      results = Promise.map(current_zone.systems) do |system|
        system_id = system.id.as(String)
        remote_driver = Driver::Proxy::RemoteDriver.new(
          sys_id: system_id,
          module_name: module_name.as(String),
          index: index.as(Int32)
        )

        output = remote_driver.exec(
          security: driver_clearance(user_token),
          function: method.as(String),
          args: args.as(Array(JSON::Any)),
          request_id: logger.request_id.as(String),
        )

        logger.tag_debug("module exec success", system_id: system_id, module_name: module_name, index: index, method: method, output: output)

        {system_id.as(String), ExecStatus::Success}
      rescue e : Driver::Proxy::RemoteDriver::Error
        handle_execute_error(e, respond: false)
        if e.error_code == Driver::Proxy::RemoteDriver::ErrorCode::ModuleNotFound
          {system_id.as(String), ExecStatus::Missing}
        else
          {system_id.as(String), ExecStatus::Failure}
        end
      end.get.not_nil!.to_a.compact # TODO implement Promise.compact_map

      response_object = results.each_with_object({
        success:        [] of String,
        failure:        [] of String,
        module_missing: [] of String,
      }) do |(id, status), obj|
        case status
        when ExecStatus::Success then obj[:success]
        when ExecStatus::Failure then obj[:failure]
        when ExecStatus::Missing then obj[:module_missing]
        end.as(Array(String)) << id
      end

      render json: response_object
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
      zone || find_zone
    end

    def find_zone
      # Find will raise a 404 (not found) if there is an error
      @zone = Model::Zone.find!(params["id"]?)
    end
  end
end
