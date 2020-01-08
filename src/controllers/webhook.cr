require "./application"

module ACAEngine::Api
  class Webhook < Application
    base "/api/engine/v2/webhook/"

    before_action :find_hook

    @trigger_instance : Model::TriggerInstance?
    @trigger : Model::Trigger?

    def show
      render json: current_trigger
    end

    alias RemoteDriver = ::ACAEngine::Driver::Proxy::RemoteDriver

    # Triggers the webhook
    def notify(method_type : String)
      trigger_instance = current_trigger_instance
      trigger = current_trigger

      # Notify the trigger service
      trigger_uri = URI.parse(host: "triggers", port: 8080)
      trigger_uri.path = "/api/triggers/v2/webhook?id=#{@trigger_instance.id}&secret=#{@trigger_instance.webhook_secret}"
      response = HTTP::Client.post(
        trigger_uri,
        headers: HTTP::Headers{"X-Request-ID" => logger.request_id}
      )

      # Execute the requested method
      if params["exec"]? == "true"
        exec_params = ExecParams.new(params).validate!

        if @trigger_instance.exec_enabled
          driver = RemoteDriver.new(
            @trigger_instance.control_system_id,
            exec_params.mod,
            exec_params.index?
          )

          args = nil
          named_args = nil
          can_be_called = true
          expects_arguments = true
          body_data = body.try(&.gets_to_end) || ""

          # Check if the function accepts arguments / can be called with
          if meta = driver.metadata?
            if method_signature = meta[exec_params.method]?
              expects_arguments = false unless method_signature.size > 0

              # ensure any remaining remaining arguments are optional
              method_signature.each_with_index do |(argument, type_details), index|
                case index
                when 0
                  if type_details[0].starts_with?("String")
                    args = [method_type.to_json]
                  else
                    can_be_called = false unless type_details.size > 1
                    expects_arguments = false
                  end
                when 1
                  if expects_arguments && type_details[0].starts_with?("String")
                    args.not_nil! << body_data.to_json
                  else
                    can_be_called = false unless type_details.size > 1
                  end
                else
                  # break as if index > 1 has defaults then they all have defaults
                  can_be_called = false unless type_details.size > 1
                  break
                end
              end
            end
          end

          if can_be_called
            response = driver.exec(
              RemoteDriver::Clearance::User,
              exec_params.method,
              args,
              named_args,
              logger.request_id
            )

            # We expect that the method being called is aware of its role as a trigger
            if !response.empty?
              begin
                response_code, response_headers, response_body = Tuple(Int32, Hash(String, String)?, String?).from_json(response)

                if response_headers
                  response_headers.each { |key, value| response.headers[key] = value }
                end

                # These calls to render will return
                if response_body && !response_body.empty?
                  render response_code, text: response_body
                else
                  head response_code
                end
              rescue
                logger.warn "trigger function response not valid #{@trigger_instance.control_system_id} - #{exec_params.friendly}"
              end
            end
          else
            logger.warn "invalid function signature for trigger #{@trigger_instance.id} - #{exec_params.friendly}"
          end
        else
          logger.warn "attempt to execute function on trigger #{@trigger_instance.id} - #{exec_params.friendly}"
        end
      end

      head :accepted if response.success?
      head :not_found
    end

    {% for http_method in ActionController::Router::HTTP_METHODS %}
      {{http_method.id}} "/:id/notify" do
        return notify({{http_method.id.stringify.upcase}}) if @trigger.supported_method? {{http_method.id.stringify.upcase}}
        logger.warn "attempt to notify trigger #{@trigger_instance.id} with unsupported method #{{{http_method.id.stringify}}}"
        head :not_found
      end
    {% end %}

    class WebhookParams < Params
      attribute id : String
      attribute secret : String

      validates :id, presence: true
      validates :secret, presence: true
    end

    class ExecParams < WebhookParams
      attribute mod : String
      attribute index : String? = nil
      attribute method : String

      def index?
        if i = @index
          i.to_i
        else
          1
        end
      end

      def friendly
        "#{@mod}_#{index?}.#{method}"
      end

      validates :mod, presence: true
      validates :method, presence: true
    end

    def find_hook
      args = WebhookParams.new(params).validate!

      # Find will raise a 404 (not found) if there is an error
      trigger_instance = Model::TriggerInstance.find!(args.id)
      trigger = trigger_instance.trigger

      # Determine the validity of loaded TriggerInstance
      unless trigger_instance.enabled &&
             trigger_instance.webhook_secret == args.secret &&
             trigger
        head :not_found
      end

      @trigger_instance = trigger_instance
      @trigger = trigger
    end

    def current_trigger
      return @trigger.as(Model::Trigger) if @trigger
      find_hook
      current_trigger
    end

    def current_trigger_instance
      return @trigger_instance.as(Model::TriggerInstance) if @trigger_instance
      find_hook
      current_trigger_instance
    end
  end
end
