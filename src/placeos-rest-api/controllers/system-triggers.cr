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
        parameters:
          #{Schema.qp "complete", "The maximum numbers of zones to return", type: "boolean"}
          #{Schema.qp "important", "Filter by importance", type: "boolean"}
          #{Schema.qp "triggered", "Filter by triggered", type: "boolean"}
          #{Schema.qp "trigger_id", "Filter by trigger ID", type: "string"}
          #{Schema.qp "as_of", "occurred before a particular time", type: "integer"}
          #{Schema.qp "sys_id", "Filter by system ID", type: "string"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array Model::TriggerInstance}
      YAML
    )]
    def index
      elastic = Model::TriggerInstance.elastic
      query = elastic.query(params)
      args = IndexParams.new(params)
      control_system_id = params["sys_id"]

      # Filter by system ID
      query.must({"control_system_id" => [control_system_id]})

      # Filter by trigger ID
      if (trigger_id = args.trigger_id)
        query.filter({"trigger_id" => [trigger_id]})
      end

      # That occurred before a particular time
      if (as_of = args.as_of)
        query.range({
          "updated_at" => {
            :lte => as_of,
          },
        })
      end

      # Filter by importance
      if args.important
        query.filter({"important" => [true]})
      end

      # Filter by triggered
      if args.triggered
        query.filter({"triggered" => [true]})
      end

      # Include parent documents in the search
      query.has_parent(parent: Model::Trigger, parent_index: Model::Trigger.table_name)

      trigger_instances = paginate_results(elastic, query).map { |t| render_system_trigger(t, complete: args.complete.as(Bool)) }

      render json: trigger_instances
    end

    @[OpenAPI(
      <<-YAML
        summary: get current trigger instance in system
        parameters:
          #{Schema.qp "complete", "choose to render extra association fields", type: "boolean"}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Model::TriggerInstance}
      YAML
    )]
    def show
      # Default to render extra association fields
      complete = boolean_param("complete", default: true)
      render json: render_system_trigger(current_sys_trig, complete: complete)
    end

    class UpdateParams < Params
      attribute enabled : Bool?
      attribute important : Bool?
      attribute exec_enabled : Bool?
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a trigger instance
        parameters:
          #{Schema.qp "enabled", "", type: "boolean"}
          #{Schema.qp "important", "", type: "boolean"}
          #{Schema.qp "exec_enabled", "", type: "boolean"}
        requestBody:
          required: true
          content:
            #{Schema.ref Model::TriggerInstance}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Model::TriggerInstance}
      YAML
    )]
    def update
      args = UpdateParams.from_json(self.body)

      current_sys_trig.enabled = args.enabled.as(Bool) unless args.enabled.nil?
      current_sys_trig.important = args.important.as(Bool) unless args.important.nil?
      current_sys_trig.exec_enabled = args.exec_enabled.as(Bool) unless args.exec_enabled.nil?

      save_and_respond(current_sys_trig)
    end

    put_redirect

    @[OpenAPI(
      <<-YAML
        summary: Create a trigger instance
        requestBody:
          required: true
          content:
            #{Schema.ref Model::TriggerInstance}
        security:
        - bearerAuth: []
        responses:
          422:
            description: Unprocessable Entity
          201:
            description: OK
            content:
              #{Schema.ref Model::TriggerInstance}
      YAML
    )]
    def create
      model = Model::TriggerInstance.from_json(self.body)

      if model.control_system_id != current_system.id
        render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "control_system_id mismatch")
      else
        save_and_respond model
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a trigger instance
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
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
