require "spec"
require "rethinkdb-orm"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"

# Generators for Engine models
require "../lib/engine-models/spec/generator"

# Configure DB
DB_NAME = "test_#{Time.now.to_unix}_#{rand(10000)}"
RethinkORM::Connection.configure do |settings|
  settings.db = DB_NAME
end

# Tear down the test database
at_exit do
  RethinkORM::Connection.raw do |q|
    q.db_drop(DB_NAME)
  end
end
