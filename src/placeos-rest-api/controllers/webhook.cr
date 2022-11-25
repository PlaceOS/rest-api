require "./application"

module PlaceOS::Api
  class Webhook < Application
    base "/api/engine/v2/webhook/"

    # Callbacks
    ###############################################################################################

    skip_action :authorize!, except: [:show]
    skip_action :set_user_id, except: [:show]

    # Find the trigger details that represent this webhook
    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:show])]
    def check_body
      @body_data = request.body.try(&.gets_to_end) || ""
      request.body = nil
    end

    @[AC::Route::Filter(:before_action)]
    def find_hook(
      id : String,
      secret : String
    )
      Log.context.set(trigger_instance_id: id)

      # Find will raise a 404 (not found) if there is an error
      trigger_instance = Model::TriggerInstance.find!(id)
      trigger = trigger_instance.trigger

      # Determine the validity of loaded TriggerInstance
      unless trigger_instance.enabled &&
             trigger_instance.webhook_secret == secret &&
             trigger
        raise Error::NotFound.new
      end

      Log.context.set(trigger_id: trigger.id)

      @current_trigger_instance = trigger_instance
      @current_trigger = trigger
    end

    getter! current_trigger_instance : Model::TriggerInstance
    getter! current_trigger : Model::Trigger
    getter body_data : String = ""

    # Check if there are any execute params
    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:show])]
    def exec_details(
      @exec : Bool = false,
      @mod : String? = nil,
      @index : Int32 = 1,
      @method : String? = nil
    )
    end

    getter? exec : Bool = false
    getter! mod : String
    getter index : Int32 = 1
    getter! method : String

    def mod_friendly_name
      "#{mod}_#{index}.#{method}"
    end

    ###############################################################################################

    # returns the details of a webhook trigger
    @[AC::Route::GET("/:id")]
    def show : Model::Trigger
      current_trigger
    end

    alias RemoteDriver = ::PlaceOS::Driver::Proxy::RemoteDriver

    # Triggers the webhook
    def notify(method_type : String) # ameba:disable Metrics/CyclomaticComplexity
      # Notify the trigger service
      trigger_uri = TRIGGERS_URI.dup
      trigger_uri.path = "/api/triggers/v2/webhook?id=#{current_trigger_instance.id}&secret=#{current_trigger_instance.webhook_secret}"
      trigger_response = HTTP::Client.post(
        trigger_uri,
        headers: HTTP::Headers{"X-Request-ID" => request_id}
      )

      # Execute the requested method
      if exec?
        raise ::AC::Route::Param::MissingError.new("missing required parameter", "mod", "String") if @mod.nil?
        raise ::AC::Route::Param::MissingError.new("missing required parameter", "method", "String") if @method.nil?

        if current_trigger_instance.exec_enabled
          driver = RemoteDriver.new(
            current_trigger_instance.control_system_id.as(String),
            mod,
            index
          )

          header_data = request.headers.try(&.to_h) || Hash(String, Array(String)).new
          header_data["pos-query-params"] = [query_params.to_s]

          args = {method_type, header_data, body_data}

          exec_response, _status_code = driver.exec(
            security: RemoteDriver::Clearance::Support,
            function: method,
            args: args,
            request_id: request_id,
            user_id: "webhook #{current_trigger_instance.id}"
          )

          # We expect that the method being called is aware of its role as a trigger
          if !exec_response.empty?
            Log.debug { "webhook exec response: #{exec_response}" }
            begin
              response_code, response_headers, response_body = Tuple(Int32, Hash(String, String)?, String?).from_json(exec_response)

              if response_headers
                # Forward response headers from the remote driver
                response_headers.each { |key, value| @context.response.headers[key] = value }
              end

              # These calls to render will return
              if response_body && !response_body.empty?
                render response_code, text: response_body
              else
                head response_code
              end
            rescue error
              Log.info(exception: error) { "trigger function response not valid #{current_trigger_instance.control_system_id} - #{mod_friendly_name}" }
            end
          end
        else
          Log.warn { "attempt to execute function on trigger #{current_trigger_instance.id} - #{mod_friendly_name}" }
        end
      end

      head :accepted if trigger_response.success?
      head :not_found
    end

    {% for http_method in ActionController::Router::HTTP_METHODS.reject &.==("head") %}
      {{http_method.id}} "/:id/notify" do
        Log.info { "\n\nOLD SCHOOL NOTIFY\n\n" }
        return notify({{http_method.id.stringify.upcase}}) if current_trigger.supported_method? {{http_method.id.stringify.upcase}}
        Log.warn { "attempt to notify trigger #{current_trigger_instance.id} with unsupported method #{{{http_method.id.stringify}}}" }
        head :not_found
      end

      {{http_method.id}} "/:id/notify/:secret" do
        Log.info { "\n\nSIMPLE SECRET\n\n" }
        return notify({{http_method.id.stringify.upcase}}) if current_trigger.supported_method? {{http_method.id.stringify.upcase}}
        Log.warn { "attempt to notify trigger #{current_trigger_instance.id} with unsupported method #{{{http_method.id.stringify}}}" }
        head :not_found
      end

      {{http_method.id}} "/:id/notify/:secret/:mod/:index/:method" do
        params["exec"] = "true"
        Log.info { "\n\nEXEC DIRECT\n\n" }
        return notify({{http_method.id.stringify.upcase}}) if current_trigger.supported_method? {{http_method.id.stringify.upcase}}
        Log.warn { "attempt to notify trigger #{current_trigger_instance.id} with unsupported method #{{{http_method.id.stringify}}}" }
        head :not_found
      end
    {% end %}
  end
end
