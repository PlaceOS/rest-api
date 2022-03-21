require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class SystemTriggers < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
    base "/api/engine/v2/systems/:sys_id/triggers/"
    id_param :trig_id

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, only: [:create, :update, :update_alt, :destroy]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :ensure_json, only: [:create, :update, :update_alt]
    before_action :current_system, only: [:show, :update, :update_alt, :destroy]
    before_action :current_sys_trig, only: [:show, :update, :update_alt, :destroy]
    before_action :body, only: [:create, :update, :update_alt]

    ###############################################################################################

    getter current_sys_trig : Model::TriggerInstance { find_sys_trig }
    getter current_system : Model::ControlSystem { find_system }

    class IndexParams < Params
      attribute complete : Bool = true
      attribute important : Bool = false
      attribute triggered : Bool = false
      attribute trigger_id : String?
      attribute as_of : Int32? # Unix epoch
    end

    @[OpenAPI(
      <<-YAML
        summary: get all trigger instances in system
        security:
        - bearerAuth: []
      YAML
    )]
    def index
      elastic = Model::TriggerInstance.elastic
      query = elastic.query(params)

      complete = param(complete : Bool?, description: "return full details") || false
      important = param(important : Bool?, description: "filter by importance")
      triggered = param(triggered : Bool?, description: "filter by triggered")
      trigger_id = param(trigger_id : String?, description: "filter by trigger ID")
      as_of = param(as_of : Int32?, description: "occurred before a particular time")
      control_system_id = param(sys_id : String, description: "filter by system ID")

      # Filter by system ID
      query.must({"control_system_id" => [control_system_id]})

      # Filter by trigger ID
      query.filter({"trigger_id" => [trigger_id]}) if trigger_id

      # That occurred before a particular time
      query.range({"updated_at" => {:lte => as_of}}) unless as_of.nil?

      # Filter by importance
      query.filter({"important" => [true]}) if important

      # Filter by triggered
      query.filter({"triggered" => [true]}) if triggered

      # Include parent documents in the search
      query.has_parent(parent: Model::Trigger, parent_index: Model::Trigger.table_name)

      trigger_instances = paginate_results(elastic, query).map { |t| render_system_trigger(t, complete) }

      render json: trigger_instances, type: Array(::PlaceOS::Model::TriggerInstance)
    end

    @[OpenAPI(
      <<-YAML
        summary: get current trigger instance in system
        security:
        - bearerAuth: []
      YAML
    )]
    def show
      # Default to render extra association fields
      complete = boolean_param("complete", default: true)
      render json: render_system_trigger(current_sys_trig, complete: complete), type: ::PlaceOS::Model::TriggerInstance
    end

    class UpdateParams < Params
      attribute enabled : Bool?
      attribute important : Bool?
      attribute exec_enabled : Bool?
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a trigger instance
        security:
        - bearerAuth: []
      YAML
    )]
    def update
      body_args = UpdateParams.from_json(self.body)

      current_sys_trig.enabled = body_args.enabled.as(Bool) unless body_args.enabled.nil?
      current_sys_trig.important = body_args.important.as(Bool) unless body_args.important.nil?
      current_sys_trig.exec_enabled = body_args.exec_enabled.as(Bool) unless body_args.exec_enabled.nil?
      current_sys_trig.save!
      render json: current_sys_trig, type: ::PlaceOS::Model::TriggerInstance
    end

    put_redirect

    @[OpenAPI(
      <<-YAML
        summary: Create a trigger instance
        security:
        - bearerAuth: []
      YAML
    )]
    def create
      trigger_instance = body_as ::PlaceOS::Model::TriggerInstance, constructor: :from_json

      if trigger_instance.control_system_id != current_system.id
        render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "control_system_id mismatch")
      else
        save_and_respond trigger_instance
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a trigger instance
        security:
        - bearerAuth: []
      YAML
    )]
    def destroy
      current_sys_trig.destroy # Expires the cache in after callback
      head :ok
    end

    # Helpers
    ###########################################################################

    # Render a TriggerInstance
    # - excludes `webhook_secret` if authorized user has a support role (or lower)
    # - includes `name`, `id` of parent ControlSystem, and `name` of if `complete = true`
    def render_system_trigger(trigger_instance : Model::TriggerInstance, complete : Bool = false)
      cs = trigger_instance.control_system
      # Support users (and below) cannot access webhook links
      except = is_admin? ? nil : ["webhook_secret"]
      restrict_attributes(trigger_instance,
        fields: {
          :name           => trigger_instance.trigger.try &.name,
          :control_system => {
            name: cs.try &.name,
            id:   cs.try &.id,
          },
        },
        except: except,
      )
    end

    protected def find_system
      id = params["sys_id"]
      Log.context.set(control_system_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::ControlSystem.find!(id, runopts: {"read_mode" => "majority"})
    end

    protected def find_sys_trig
      id = params["trig_id"]
      Log.context.set(trigger_instance_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::TriggerInstance.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
