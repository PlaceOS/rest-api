require "./application"

module Engine::API
  class SystemTriggers < Application
    base "/api/v1/systems/:id/triggers/"

    # state, funcs, count and types are available to authenticated users
    # before_action :check_admin,   only: [:create, :update, :destroy]
    # before_action :check_support, only: [:index, :show]

    before_action :ensure_json, only: [:create, :update]
    before_action :find_sys_trig, only: [:show, :update, :destroy]

    @sys_trig : Model::TriggerInstance?
    getter :sys_trig

    # SYS_INCLUDE =
    #     include: {
    #         # include control system on logic modules so it is possible
    #         # to display the inherited settings
    #         control_system: {
    #             only: [:name, :id],
    #         }
    #     }
    # }
    # # Support users cannot access webhook links
    # SUPPORT_ONLY = { except: [:webhook_secret] }
    # SYS_INCLUDE_SUPPORT = SYS_INCLUDE.merge(SUPPORT_ONLY)

    class IndexParams < Params
      attribute control_system_id : String
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
      if params.has_key? "important"
        query.filter({"doc.important" => [true]})
      end

      # Filter by triggered
      if params.has_key? "triggered"
        query.filter({"doc.triggered" => [true]})
      end

      # Include parent documents in the search
      query.has_parent(parent: Model::Trigger, parent_index: Model::Trigger.table_name)

      results = elastic.search(query)

      # Awaiting User logic
      # user = current_user
      # if args.trigger_id
      #     if user.support && !user.sys_admin
      #         render json: restrict_attributes(results.as_json(SYS_INCLUDE_SUPPORT))
      #     else
      #         sys_included = results.map do |r|
      #           cs = r.cs
      #           name = cs.try &.name
      #           id = cs.try &.id
      #           with_fields(r, { :control_system => { name: name, id: id } })
      #         end
      #
      #         render json: sys_included
      #     end
      # elsif user.support && !user.sys_admin
      #     render json: results.as_json(SUPPORT_ONLY)
      # else
      #     render json: results
      # end

      render json: results
    end

    get("/:trigger_id", :show) do
      # if user.support && !user.sys_admin
      #   render json: restrict_attributes(@sys_trig, exclude: ["webhook_secret"])
      # else
      render json: @sys_trig
      # end
    end

    class UpdateParams < Params
      attribute enabled : Bool
      attribute important : Bool
    end

    patch("/:trigger_id", :update) do
      sys_trig = @sys_trig.not_nil!
      body = request.body.not_nil!
      args = UpdateParams.from_json(body)

      sys_trig.enabled = args.enabled unless args.enabled.nil?
      sys_trig.important = args.important unless args.important.nil?

      save_and_respond(sys_trig)
    end

    post("/:trigger_id", :create) do
      body = request.body.not_nil!
      save_and_respond Model::TriggerInstance.from_json(body)
    end

    delete("/:trigger_id", :delete) do
      @sys_trig.try &.destroy # expires the cache in after callback
      head :ok
    end

    def find_sys_trig
      # Find will raise a 404 (not found) if there is an error
      @sys_trig = Model::TriggerInstance.find!(params["trigger_id"]?)
    end
  end
end
