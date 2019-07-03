require "spec"
require "random"
require "rethinkdb-orm"

require "./generator"

db_name = "test_#{Time.now.to_unix}_#{rand(10000)}"
Engine::Model::Connection.configure do |settings|
  settings.db = db_name
end

# Tear down the test database
at_exit do
  Engine::Model::Connection.raw do |q|
    q.db_drop(db_name)
  end
end

# Pretty prints document errors
def inspect_error(error : RethinkORM::Error::DocumentInvalid)
  errors = error.model.errors.map do |e|
    {
      field:   e.field,
      message: e.message,
    }
  end
  pp! errors
end
