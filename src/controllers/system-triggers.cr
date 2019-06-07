require "./application"

module Engine::API
  class SystemTriggers < Application
    include Utils::CurrentUser

    base "/api/v1/systems/:sys_id/triggers/"
    id_param :trig_id

    # state, funcs, count and types are available to authenticated users
    # before_action :check_admin,   only: [:create, :update, :destroy]
    # before_action :check_support, only: [:index, :show]

    before_action :ensure_json, only: [:create, :update]
    before_action :find_sys_trig, only: [:show, :update, :destroy]

    @sys_trig : Model::TriggerInstance?
    getter :sys_trig

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
      if args.control_system_id
        query.filter({"doc.control_system_id" => [args.control_system_id.not_nil!]})
      end

      # Filter by trigger ID
      if args.trigger_id
        query.filter({"doc.trigger_id" => [args.trigger_id.not_nil!]})
      end

      # That occured before a particular time
      # if args.as_of
      #   query.range({
      #     "doc.updated_at" => {
      #       :lte => args.as_of,
      #     },
      #   })
      # end

      # Filter by importance
      if args.important
        query.filter({"doc.important" => [true]})
      end

      # Filter by triggered
      if args.triggered
        query.filter({"doc.triggered" => [true]})
      end

      # Include parent documents in the search
      query.has_parent(parent: Model::Trigger, parent_index: Model::Trigger.table_name)

      results = elastic.search(query)[:results]
      users = render_users(results, args.trigger_id)
      render json: {
        results: users,
        total:   users.size,
      }
    end

    # Render a collection of users
    # - excludes :webhook_secret if authorized user has a support role
    # - includes :name, :id of parent ControlSystem if passed trigger id
    protected def render_users(users, trigger_id = nil)
      # TODO: Review on auth completion
      user = current_user.not_nil!
      if trigger_id
        # Include ControlSystem
        users.map do |r|
          cs = r.control_system

          # Sa port users cannot access webhook links
          except = user.support && !user.sys_admin ? ["webhook_secret"] : nil
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
      elsif user.support && !user.sys_admin
        # Support users cannot access webhook links
        users.map { |r| restrict_attributes(r, except: ["webhook_secret"]) }
      else
        users
      end
    end

    def show
      user = current_user.not_nil!
      sys_trig = @sys_trig.not_nil!
      if user.support && !user.sys_admin
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
      sys_trig = @sys_trig.not_nil!
      body = request.body.not_nil!
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
      @sys_trig.try &.destroy # expires the cache in after callback
      head :ok
    end

    def find_sys_trig
      # Find will raise a 404 (not found) if there is an error
      @sys_trig = Model::TriggerInstance.find!(params["trig_id"]?)
    end
  end
end
