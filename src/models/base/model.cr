require "active-model"
require "json"
require "neuroplastic"
require "rethinkdb-orm"
require "semantic_version"

require "../utils/*"

module Engine::Model
  # Base class for all Engine models
  abstract class ModelBase < RethinkORM::Base
    include Neuroplastic
  end

  # Validation for embedded objects in Engine models
  abstract class SubModel < ActiveModel::Model
    include ActiveModel::Validation

    # RethinkDB library serializes through JSON::Any
    def to_reql
      JSON::Any.new(self.to_json)
    end

    # Propagate submodel validation errors to parent's
    protected def collect_errors(collection : Symbol, models)
      errors = models.compact_map do |m|
        m.errors unless m.valid?
      end
      errors.flatten.each do |e|
        self.validation_error(field: collection, message: e.to_s.downcase)
      end
    end
  end
end
