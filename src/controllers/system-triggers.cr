require "./application"

module Engine::API
  class SystemTriggers < Application
    include Utils::CurrentUser

    base "/api/v1/systems/:sys_id/triggers/"
    id_param :trig_id

    # state, funcs, count and types are available to authenticated users
    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    before_action :ensure_json, only: [:create, :update]
    before_action :find_sys_trig, only: [:show, :update, :destroy]

    @sys_trig : Model::TriggerInstance?

    class IndexParams < Params
      attribute control_system_id : String
      attribute important : Bool = false
      attribute triggered : Bool = false
      attribute trigger_id : String
      attribute as_of : Int32 # Unix epoch
    end

    def index
      elastic = Model::TriggerInstance.elastic
      query = elastic.query(params)
      args = IndexParams.new(params)

      # Filter by system ID
      if (control_system_id = args.control_system_id)
        query.filter({"control_system_id" => [control_system_id]})
      end

      # Filter by trigger ID
      if (trigger_id = args.trigger_id)
        query.filter({"trigger_id" => [trigger_id]})
      end

      # That occured before a particular time
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

      results = elastic.search(query)[:results]
      system_triggers = render_system_triggers(results, args.trigger_id)
      render json: {
        results: system_triggers,
        total:   system_triggers.size,
      }
    end

    # Render a collection of TriggerInstances
    # - excludes :webhook_secret if authorized user has a support role
    # - includes :name, :id of parent ControlSystem if passed trigger id
    protected def render_system_triggers(system_triggers, trigger_id = nil)
      if trigger_id
        # Include ControlSystem
        system_triggers.map do |r|
          cs = r.control_system

          # Support users cannot access webhook links
          except = is_support? && !is_admin? ? ["webhook_secret"] : nil
          restrict_attributes(r,
            fields: {
              :control_system => {
                name: cs.try &.name,
                id:   cs.try &.id,
              },
            },
            except: except,
          )
        end
      elsif is_support? && !is_admin?
        # Support users cannot access webhook links
        system_triggers.map { |r| restrict_attributes(r, except: ["webhook_secret"]) }
      else
        system_triggers
      end
    end

    def show
      sys_trig = @sys_trig.as(Model::TriggerInstance)
      if is_support? && !is_admin?
        render json: restrict_attributes(sys_trig, except: ["webhook_secret"])
      else
        render json: sys_trig
      end
    end

    class UpdateParams < Params
      attribute enabled : Bool
      attribute important : Bool
    end

    def update
      body = request.body.not_nil!
      sys_trig = @sys_trig.as(Model::TriggerInstance)

      args = UpdateParams.from_json(body)

      sys_trig.enabled = args.enabled unless args.enabled.nil?
      sys_trig.important = args.important unless args.important.nil?

      save_and_respond(sys_trig)
    end

    def create
      body = request.body.not_nil!
      save_and_respond Model::TriggerInstance.from_json(body)
    end

    def destroy
      @sys_trig.try &.destroy # Expires the cache in after callback
      head :ok
    end

    def find_sys_trig
      # Find will raise a 404 (not found) if there is an error
      @sys_trig = Model::TriggerInstance.find!(params["trig_id"]?)
    end
  end
end
