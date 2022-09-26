require "action-controller"
require "placeos-models"
require "uuid"

require "../error"
require "../utilities/*"

module PlaceOS::Api
  abstract class Application < ActionController::Base
    macro inherited
      Log = ::PlaceOS::Api::Log.for(self)
    end

    # Customise the request body parser
    add_parser("application/json") do |klass, body_io|
      if klass < ActiveModel::Model
        object = klass.new
        # we clear the changes information so we can track what was assigned from the JSON
        object.clear_changes_information
        object.assign_attributes_from_json(body_io)
        object
      else
        klass.from_json(body_io)
      end
    end

    # Helpers for controller responses
    include Utils::Responders

    # Helpers for determining picking off user from JWT, authorization
    include Utils::CurrentUser

    # Helpers for defining scope checks on controller actions
    include Utils::Scopes

    # For want of route templating, this module exists
    include Utils::PutRedirect

    # Core service discovery
    class_getter core_discovery : Discovery::Core { Discovery::Core.instance }

    # Default sort for elasticsearch
    NAME_SORT_ASC = {"name.keyword" => {order: :asc}}

    # TODO:: remove
    macro required_param(key)
      if (%value = {{ key }}).nil?
        return render_error(HTTP::Status::BAD_REQUEST, "Missing '{{ key }}' param")
      else
        %value
      end
    end

    # TODO:: remove
    def boolean_param(key : String, default : Bool = false, allow_empty : Bool = false) : Bool
      return true if allow_empty && params.has_key?(key) && params[key].nil?

      case params[key]?.presence.try(&.downcase)
      when .in?("1", "true")  then true
      when .in?("0", "false") then false
      else                         default
      end
    end

    def paginate_results(elastic, query, route = base_route)
      data = elastic.search(query)
      range_start = query.offset
      range_end = data[:results].size + range_start
      total_items = data[:total]
      item_type = elastic.elastic_index
      response.headers["X-Total-Count"] = total_items.to_s
      # response.headers["Accept-Ranges"] = item_type
      response.headers["Content-Range"] = "#{item_type} #{range_start}-#{range_end}/#{total_items}"

      if range_end < total_items
        query_params["offset"] = (range_end + 1).to_s
        query_params["limit"] = query.limit.to_s
        if ref = data[:ref]
          query_params["ref"] = ref
        end
        response.headers["Link"] = %(<#{route}?#{query_params}>; rel="next")
      end

      data[:results]
    end

    def set_collection_headers(size : Int32, content_type : String)
      response.headers["X-Total-Count"] = size.to_s
      response.headers["Content-Range"] = "#{content_type} 0-#{size - 1}/#{size}"
    end

    getter! search_params : Hash(String, String)

    @[AC::Route::Filter(:before_action, only: [:index])]
    def build_search_params(
      @[AC::Param::Info(name: "q", description: "returns results based on a [simple query string](https://www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl-simple-query-string-query.html)")]
      query : String = "*",
      @[AC::Param::Info(description: "the maximum number of results to return", example: "10000")]
      limit : UInt32 = 100_u32,
      @[AC::Param::Info(description: "deprecated, the starting offset of the result set. Used to implement pagination")]
      offset : UInt32 = 0_u32,
      @[AC::Param::Info(description: "a token for accessing the next page of results, provided in the `Link` header")]
      ref : String? = nil
    )
      search_params = {
        "q"      => query,
        "limit"  => limit.to_s,
        "offset" => offset.to_s,
      }
      search_params["ref"] = ref.not_nil! if ref.presence
      @search_params = search_params
    end

    # Callbacks
    ###########################################################################

    # All routes are authenticated, except root
    # NOTE:: we
    before_action :authorize!, except: [:root, :mqtt_user, :mqtt_access]

    # Simplifies determining user's requests in server-side logs
    @[AC::Route::Filter(:before_action, except: [:root, :mqtt_user, :mqtt_access])]
    def set_user_id
      Log.context.set(user_id: user_token.id)
    end

    # TODO:: remove
    getter body : IO do
      request_body = request.body
      raise Error::NoBody.new if request_body.nil?
      request_body
    end

    getter request_id : String { UUID.random.to_s }

    # This makes it simple to match client requests with server side logs.
    # When building microservices, this ID should be propagated to upstream services.
    @[AC::Route::Filter(:before_action)]
    def set_request_id
      if request.headers.has_key?("X-Request-ID") && @request_id.nil?
        @request_id = request.headers["X-Request-ID"]
      end

      Log.context.set(
        client_ip: client_ip,
        request_id: request_id
      )

      response.headers["X-Request-ID"] = request_id
    end

    # TODO:: remove once updated
    protected def ensure_json
      unless request.headers["Content-Type"]?.try(&.starts_with?("application/json"))
        return render_error(HTTP::Status::NOT_ACCEPTABLE, "Accepts: application/json")
      end

      body
    end

    ###########################################################################
    # Error Handlers
    ###########################################################################

    struct CommonError
      include JSON::Serializable

      getter error : String?
      getter backtrace : Array(String)?

      def initialize(error, backtrace = true)
        @error = error.message
        @backtrace = backtrace ? error.backtrace : nil
      end
    end

    # 401 if no bearer token
    @[AC::Route::Exception(Error::Unauthorized, status_code: HTTP::Status::UNAUTHORIZED)]
    def resource_requires_authentication(error) : CommonError
      Log.debug { error.message }
      CommonError.new(error, false)
    end

    # 403 if user role invalid for a route
    @[AC::Route::Exception(Error::Forbidden, status_code: HTTP::Status::FORBIDDEN)]
    def resource_access_forbidden(error) : Nil
      Log.debug { error.inspect_with_backtrace }
    end

    # 404 if resource not present
    @[AC::Route::Exception(RethinkORM::Error::DocumentNotFound, status_code: HTTP::Status::NOT_FOUND)]
    def resource_not_found(error) : CommonError
      Log.debug(exception: error) { error.message }
      CommonError.new(error, false)
    end

    # when a client request fails validation
    @[AC::Route::Exception(JSON::ParseException, status_code: HTTP::Status::BAD_REQUEST)]
    @[AC::Route::Exception(JSON::SerializableError, status_code: HTTP::Status::BAD_REQUEST)]
    @[AC::Route::Exception(RethinkORM::Error::DocumentInvalid, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
    def validation_failed(error) : CommonError
      Log.debug(exception: error) { error.message }
      CommonError.new(error, Api.production?)
    end

    # ========================
    # Model Validation Errors
    # ========================

    struct ValidationError
      include JSON::Serializable
      include YAML::Serializable

      getter error : String
      getter failures : Array(NamedTuple(field: Symbol, reason: String))

      def initialize(@error, @failures)
      end
    end

    # handles model validation errors
    @[AC::Route::Exception(Error::ModelValidation, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
    def model_validation(error) : ValidationError
      ValidationError.new error.message.not_nil!, error.failures
    end

    # ========================
    # Action Controller Errors
    # ========================

    # Provides details on available data formats
    struct ContentError
      include JSON::Serializable
      include YAML::Serializable

      getter error : String
      getter accepts : Array(String)? = nil

      def initialize(@error, @accepts = nil)
      end
    end

    # covers no acceptable response format and not an acceptable post format
    @[AC::Route::Exception(AC::Route::NotAcceptable, status_code: HTTP::Status::NOT_ACCEPTABLE)]
    @[AC::Route::Exception(AC::Route::UnsupportedMediaType, status_code: HTTP::Status::UNSUPPORTED_MEDIA_TYPE)]
    def bad_media_type(error) : ContentError
      ContentError.new error: error.message.not_nil!, accepts: error.accepts
    end

    # Provides details on which parameter is missing or invalid
    struct ParameterError
      include JSON::Serializable
      include YAML::Serializable

      getter error : String
      getter parameter : String? = nil
      getter restriction : String? = nil

      def initialize(@error, @parameter = nil, @restriction = nil)
      end
    end

    # handles paramater missing or a bad paramater value / format
    @[AC::Route::Exception(AC::Route::Param::MissingError, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
    @[AC::Route::Exception(AC::Route::Param::ValueError, status_code: HTTP::Status::BAD_REQUEST)]
    def invalid_param(error) : ParameterError
      ParameterError.new error: error.message.not_nil!, parameter: error.parameter, restriction: error.restriction
    end
  end
end
