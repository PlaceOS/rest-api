require "action-controller/logger"
require "log_helper"

require "./placeos-rest-api/constants"
require "./placeos-rest-api/controllers/application"
require "./placeos-rest-api/controllers/*"

module PlaceOS::Api
  Log         = ::Log.for("rest-api")
  LOG_BACKEND = ActionController.default_backend
end
