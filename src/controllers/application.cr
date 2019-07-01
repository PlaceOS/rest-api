require "active-model"
require "engine-models"
require "uuid"

require "../constants"
require "../error"
require "../utils/*"

module Engine::API
  abstract class Params < ActiveModel::Model
    # Helpers for model validations
    include ActiveModel::Validation

    # Checks that the model is valid
    # Responds with the validation errors
    def validate!
      raise Error::InvalidParams.new(self) unless self.valid?
      self
    end
  end

  private abstract class Application < ActionController::Base
    # Decode JWT here
    # Lazy instantition of user, sets request.user_id

    # Helpers for controller responses
    include Utils::Responders

    # Helpers for determing picking off user from JWT, authorization
    include Utils::CurrentUser

    NAME_SORT_ASC = {"name" => {order: :asc}}

    # Callback to enforce JSON request body
    protected def ensure_json
      unless request.headers["Content-Type"]? == "application/json"
        render status: :not_acceptable, text: "Accepts: application/json"
      end
    end

    before_action :set_user_id

    # This makes it simple to determine user's requests in server side logs.
    def set_user_id
      # Grab user_id from token
      if (user_id = parse_user_token.try &.id)
        request.user_id = user_id
      end
      # Otherwise grab from params? params["user_id"]?
    end

    before_action :set_request_id

    # This makes it simple to match client requests with server side logs.
    # When building microservices this ID should be propagated to upstream services.
    def set_request_id
      response.headers["X-Request-ID"] = request.id = UUID.random.to_s
    end

    # 403 if user role invalid for a route
    rescue_from Error::Unauthorized do |error|
      self.settings.logger.debug error

      head :forbidden
    end

    # 404 if resource not present
    rescue_from RethinkORM::Error::DocumentNotFound do |error|
      self.settings.logger.debug error

      head :not_found
    end

    # 422 if resource fails validation before mutation
    rescue_from Error::InvalidParams do |error|
      self.settings.logger.debug error

      render status: :unprocessable_entity, json: error.params.errors.map(&.to_s)
    end

    # 401 if JWT parsing fails, or is not present
    rescue_from JWT::Error do |error|
      self.settings.logger.debug error
      pp! error

      head :unauthorized
    end

    # 401 if bearer is missing
    rescue_from Error::MissingBearer do |error|
      self.settings.logger.debug error

      head :unauthorized
    end
  end
end
