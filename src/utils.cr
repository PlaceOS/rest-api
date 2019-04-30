require "action-controller"

require "./error"

module Engine::API
  module Utils
    # Raises Error::ParameterMissing if a required parameter is not found
    # Looks up keys, returns tuple of values after lookup
    def self.required_params(params, *keys)
      # Raise if any missing keys
      missing_keys = keys.to_a - params.keys
      raise Error::ParameterMissing.new("Missing parameters: #{missing_keys.join(", ")}") unless missing_keys.empty?

      params.values_at(*keys)
    end
  end
end
