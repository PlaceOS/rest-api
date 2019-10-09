require "rethinkdb-orm"

require "./models/base/*"

module ACAEngine::Model
  # Expose RethinkDB connection
  # Use for configuration, raw queries
  class Connection < RethinkORM::Connection
  end
end

require "./models/*"
