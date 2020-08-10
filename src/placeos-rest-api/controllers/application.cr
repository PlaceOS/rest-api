require "action-controller"
require "placeos-models"
require "uuid"

require "../error"
require "../utilities/*"

module PlaceOS::Api
  private abstract class Application < ActionController::Base
    Log = ::PlaceOS::Api::Log.for("controller")

    # Helpers for controller responses
    include Utils::Responders

    # Helpers for determing picking off user from JWT, authorization
    include Utils::CurrentUser

    # Default sort for elasticsearch
    NAME_SORT_ASC = {"name.keyword" => {order: :asc}}

    def paginate_results(elastic, query, route = base_route)
      data = elastic.search(query)
      range_start = query.offset
      range_end = data[:results].size + range_start
      total_items = data[:total]
      item_type = elastic.elastic_index
      response.headers["X-Total-Count"] = total_items.to_s
      # response.headers["Accept-Ranges"] = item_type
      response.headers["Content-Range"] = "#{item_type} #{range_start}-#{range_end}/#{total_items}"
      if range_end < total_items
        params["offset"] = (range_end + 1).to_s
        params["limit"] = query.limit.to_s
        query_params = params.map { |key, value| "#{key}=#{value}" }.join("&")
        response.headers["Link"] = %(<#{route}?#{query_params}>; rel="next")
      end
      data[:results]
    end

    def set_collection_headers(size : Int32, content_type : String)
      response.headers["X-Total-Count"] = size.to_s
      response.headers["Content-Range"] = "#{content_type} 0-#{size - 1}/#{size}"
    end

    # Callbacks
    ###########################################################################

    before_action :set_request_id

    # All routes are authenticated, except root
    before_action :authorize!, except: [:root]

    # Simplifies determining user's requests in server-side logs
    before_action :set_user_id

    # Set user_id from parsed JWT
    def set_user_id
      Log.context.set(user_id: user_token.id)
    end

    @request_id : String? = nil

    # This makes it simple to match client requests with server side logs.
    # When building microservices, this ID should be propagated to upstream services.
    def set_request_id
      @request_id = request_id = request.headers["X-Request-ID"]? || UUID.random.to_s
      Log.context.set(
        client_ip: client_ip,
        request_id: request_id
      )
      response.headers["X-Request-ID"] = request_id
    end

    def request_id : String
      @request_id ||= UUID.random.to_s
    end

    # Callback to enforce JSON request body
    protected def ensure_json
      unless request.headers["Content-Type"]?.try(&.starts_with?("application/json"))
        render status: :not_acceptable, text: "Accepts: application/json"
      end
    end

    # Error Handlers
    ###########################################################################

    # 400 if unable to parse some JSON passed by a client
    rescue_from JSON::MappingError do |error|
      Log.debug(exception: error) { "missing/extraneous properties in client JSON" }

      if PROD
        respond_with(:bad_request) do
          text error.message
          json({error: error.message})
        end
      else
        respond_with(:bad_request) do
          text error.inspect_with_backtrace
          json({
            error:     error.message,
            backtrace: error.backtrace?,
          })
        end
      end
    end

    rescue_from JSON::ParseException do |error|
      Log.debug(exception: error) { "failed to parse client JSON" }

      if PROD
        respond_with(:bad_request) do
          text error.message
          json({error: error.message})
        end
      else
        respond_with(:bad_request) do
          text error.inspect_with_backtrace
          json({
            error:     error.message,
            backtrace: error.backtrace?,
          })
        end
      end
    end

    # 401 if no bearer token
    rescue_from Error::Unauthorized do |error|
      Log.debug { error.message }
      head :unauthorized
    end

    # 403 if user role invalid for a route
    rescue_from Error::Forbidden do |error|
      Log.debug { error.message }
      head :forbidden
    end

    # 404 if resource not present
    rescue_from RethinkORM::Error::DocumentNotFound do |error|
      Log.debug { error.message }
      head :not_found
    end

    # 422 if resource fails validation before mutation
    rescue_from Error::InvalidParams do |error|
      model_errors = error.params.errors.map(&.to_s)
      Log.debug(exception: error) { {message: "invalid params", model_errors: model_errors} }
      render status: :unprocessable_entity, json: model_errors
    end
  end
end
