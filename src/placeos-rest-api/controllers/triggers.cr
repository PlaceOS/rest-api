require "./application"

module PlaceOS::Api
  class Triggers < Application
    base "/api/engine/v2/triggers/"

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    before_action :ensure_json, only: [:create, :update, :update_alt]
    before_action :find_trigger, only: [:show, :update, :update_alt, :destroy]

    getter trig : Model::Trigger?

    def index
      elastic = Model::Trigger.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      render json: paginate_results(elastic, query)
    end

    def show
      trigger = current_trigger
      if params["instances"]? == "true"
        render json: with_fields(trigger, {
          :trigger_instances => trigger.trigger_instances.to_a,
        })
      else
        render json: trigger
      end
    end

    def update
      trig = current_trigger
      trig.assign_attributes_from_json(request.body.as(IO))
      save_and_respond(trig)
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond Model::Trigger.from_json(request.body.as(IO))
    end

    def destroy
      current_trigger.destroy # expires the cache in after callback
      head :ok
    end

    # Get instances associated with
    get "/:id/instances", :instances do
      instances = current_trigger.trigger_instances.to_a
      total_items = instances.size
      response.headers["X-Total-Count"] = total_items.to_s
      response.headers["Content-Range"] = "trigger-instance 0-#{total_items}/#{total_items}"

      render json: instances
    end

    # Helpers
    ###########################################################################

    def current_trigger
      trig || find_trigger
    end

    def find_trigger
      id = params["id"]
      Log.context.set(trigger_id: id)
      # Find will raise a 404 (not found) if there is an error
      @trig = Model::Trigger.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
