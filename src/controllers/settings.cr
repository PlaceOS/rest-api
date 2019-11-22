require "./application"

module ACAEngine::Api
  class Settings < Application
    base "/api/engine/v2/settings/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :find_settings, only: [:show, :update, :destroy]

    @settings : Model::Settings?
    getter :settings

    def index
      if params.has_key? "parent_id"
        # Directly search for model's settings, and decrypt for the user
        parent_settings = Model::Settings.for_parent(params["parent_id"])
        parent_settings.each &.decrypt_for!(current_user)

        render json: parent_settings
      else
        elastic = Model::Settings.elastic
        query = elastic.query(params)

        render json: elastic.search(query)
      end
    end

    def show
      render json: @settings.as(Model::Settings).decrypt_for!(current_user)
    end

    def update
      body = request.body.as(IO)
      settings = @settings.as(Model::Settings)

      settings.assign_attributes_from_json(body)
      save_and_respond settings
    end

    def create
      body = request.body.as(IO)
      settings = Model::Settings.from_json(body)
      save_and_respond settings
    end

    def destroy
      @settings.try &.destroy
      head :ok
    end

    def find_settings
      # Find will raise a 404 (not found) if there is an error
      @settings = Model::Settings.find!(params["id"]?)
    end
  end
end
