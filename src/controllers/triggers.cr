require "./application"

module ACAEngine::Api
  class Triggers < Application
    base "/api/engine/v2/triggers/"

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    before_action :ensure_json, only: [:create, :update]
    before_action :find_trigger, only: [:show, :update, :destroy]

    @trig : Model::Trigger?

    def index
      elastic = Model::Trigger.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      render json: elastic.search(query)
    end

    def show
      render json: current_trigger
    end

    def update
      trig = current_trigger
      trig.assign_attributes_from_json(request.body.as(IO))
      save_and_respond(trig)
    end

    def create
      save_and_respond Model::Trigger.from_json(request.body.as(IO))
    end

    def destroy
      current_trigger.destroy # expires the cache in after callback
      head :ok
    end

    # Helpers
    ###########################################################################

    def current_trigger
      return @trig.as(Model::Trigger) if @trig
      find_trigger
    end

    def find_trigger
      # Find will raise a 404 (not found) if there is an error
      @trig = Model::Trigger.find!(params["id"]?)
    end
  end
end
