require "active-model"
require "engine-models"

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
    # Helpers for determing user roles
    include Utils::AuthorizationCallbacks

    NAME_SORT_ASC = {"name" => {order: :asc}}

    # Callback to enforce JSON request body
    protected def ensure_json
      unless request.headers["Content-Type"]? == "application/json"
        render status: :not_acceptable, text: "Accepts: application/json"
      end
    end

    # 404 if resource not present
    rescue_from RethinkORM::Error::DocumentNotFound do |error| # ameba:disable Lint/UnusedArgument
      head :not_found
    end

    # 422 if resource fails validation before mutation
    rescue_from Error::InvalidParams do |error|
      render status: :unprocessable_entity, json: error.params.errors.map(&.to_s)
    end
  end
end
