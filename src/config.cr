# Application dependencies
require "action-controller"
require "rethinkdb-orm"

# Application code
require "./constants"
require "./controllers/application"
require "./controllers/*"
require "./models/*"

# Server required after application controllers
require "action-controller/server"

# Add handlers that should run before your application
ActionController::Server.before(
  HTTP::LogHandler.new(STDOUT),
  HTTP::ErrorHandler.new(ENV["SG_ENV"]? != "production"),
  HTTP::CompressHandler.new
)

# Configure session cookies
# NOTE:: Change these from defaults
ActionController::Session.configure do
  settings.key = ENV["COOKIE_SESSION_KEY"]? || "_spider_gazelle_"
  settings.secret = ENV["COOKIE_SESSION_SECRET"]? || "4f74c0b358d5bab4000dd3c75465dc2c"
end
