require "action-controller/logger"
require "log_helper"

require "./rest-api/constants"
require "./rest-api/controllers/application"
require "./rest-api/controllers/*"

module PlaceOS::Api
  Log         = ::Log.for("rest-api")
  LOG_BACKEND = ActionController.default_backend
end
