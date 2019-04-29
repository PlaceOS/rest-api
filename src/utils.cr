require "action-controller"

require "./error"

module Engine::API
  module Utils
    # Raises Error::ParameterMissing if a required parameter is not found
    # Looks up keys, returns tuple of values after lookup
    def required_params(params, *keys)
      # Raise if any missing keys
      missing_keys = keys.to_a - params.keys
      raise Error::ParameterMissing.new("Missing parameters: #{missing_keys.join(", ")}") unless missing_keys.empty?

      params.values_at(*keys)
    end

    # Shortcut to save a record and render a response
    def save_and_respond(resource)
      creation = resource.new_record?
      if resource.save
        status = creation ? :created : :ok
        render json: resource, status: status
      else
        render json: resource.errors, status: :unprocessable_entity
      end
    end
  end
end
