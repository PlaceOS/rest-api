require "./application"

module ACAEngine::Api
  class Webhook < Application
    base "/api/engine/v2/webhook/"

    before_action :find_hook

    @trigger_instance : Model::TriggerInstance?
    @trigger : Model::Trigger?

    def show
      return notify if params["exec"]? == "true"

      render json: current_trigger
    end

    # Triggers the webhook
    post("/:id/notify", :notify) do
      trigger_instance = current_trigger_instance
      trigger = current_trigger

      # TODO:

      head :accepted
    end

    class WebhookParams < Params
      attribute id : String
      attribute secret : String

      validates :id, presence: true
      validates :secret, presence: true
    end

    class ExecParams < WebhookParams
      attribute mod : String
      attribute method : String

      # TODO: Generic? Stringly typed? Explicit? Whatever this is?
      attribute args : Array(String | Int64 | Float64) = [] of String | Int64 | Float64

      attribute metadata : String
      attribute index : String

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
