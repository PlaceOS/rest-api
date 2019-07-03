require "./application"

module Engine::API
  class Triggers < Application
    base "/api/v1/triggers/"

    # state, funcs, count and types are available to authenticated users
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
      render json: @trig
    end

    def update
      trig = @trig.not_nil!
      body = request.body.not_nil!

      trig.assign_attributes_from_json(body)
      save_and_respond(trig)
    end

    def create
      body = request.body.not_nil!

      trig = Model::Trigger.from_json(body)
      save_and_respond trig
    end

    def destroy
      @trig.try &.destroy # expires the cache in after callback
      head :ok
    end

    def find_trigger
      # Find will raise a 404 (not found) if there is an error
      @trig = Model::Trigger.find!(params["id"]?)
    end
  end
end
