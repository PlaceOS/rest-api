require "action-controller"
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
    # Helpers for controller responses
    include Utils::Responders

    # Helpers for determing picking off user from JWT, authorization
    include Utils::CurrentUser

    # Default sort for elasticsearch
    NAME_SORT_ASC = {"name" => {order: :asc}}

    # Callbacks
    ###########################################################################

    # All routes are authenticated
    before_action :authorize!

    # Simplifies determining user's requests in server-side logs
    before_action :set_user_id

    # Set user_id from parsed JWT
    def set_user_id
      request.user_id = user_token.id
    end

    before_action :set_request_id

    # This makes it simple to match client requests with server side logs.
    # When building microservices, this ID should be propagated to upstream services.
    def set_request_id
      response.headers["X-Request-ID"] = request.id = UUID.random.to_s
    end

    # Callback to enforce JSON request body
    protected def ensure_json
      unless request.headers["Content-Type"]? == "application/json"
        render status: :not_acceptable, text: "Accepts: application/json"
      end
    end

    # Error Handlers
    ###########################################################################

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
  end
end
