require "action-controller"
require "engine-models"
require "uuid"

require "../constants"
require "../error"
require "../utilities/*"

module ACAEngine::Api
  private abstract class Application < ActionController::Base
    # Helpers for controller responses
    include Utils::Responders

    # Helpers for determing picking off user from JWT, authorization
    include Utils::CurrentUser

    # Default sort for elasticsearch
    NAME_SORT_ASC = {"name" => {order: :asc}}

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
        response.headers["Link"] = %(<#{route}?offset=#{range_end + 1}&limit=#{query.limit}>; rel="next")
      end
      data[:results]
    end

    # Callbacks
    ###########################################################################

    # All routes are authenticated
    before_action :authorize!

    # Simplifies determining user's requests in server-side logs
    before_action :set_user_id

    # Set user_id from parsed JWT
    def set_user_id
      logger.user_id = user_token.id
    end

    before_action :set_request_id

    # This makes it simple to match client requests with server side logs.
    # When building microservices, this ID should be propagated to upstream services.
    def set_request_id
      response.headers["X-Request-ID"] = logger.request_id = UUID.random.to_s
    end

    # Callback to enforce JSON request body
    protected def ensure_json
      unless request.headers["Content-Type"]? == "application/json"
        render status: :not_acceptable, text: "Accepts: application/json"
      end
    end

    # Error Handlers
    ###########################################################################

    # 400 if unable to parse some JSON passed by a client
    rescue_from JSON::MappingError do |error|
      logger.debug error

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
      logger.debug error

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
      logger.debug error
      head :unauthorized
    end

    # 403 if user role invalid for a route
    rescue_from Error::Forbidden do |error|
      logger.debug error
      head :forbidden
    end

    # 404 if resource not present
    rescue_from RethinkORM::Error::DocumentNotFound do |error|
      logger.debug error
      head :not_found
    end

    # 422 if resource fails validation before mutation
    rescue_from Error::InvalidParams do |error|
      logger.debug error
      render status: :unprocessable_entity, json: error.params.errors.map(&.to_s)
    end
  end
end
