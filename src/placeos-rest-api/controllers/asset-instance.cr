require "./application"

module PlaceOS::Api
  class AssetInstances < Application
    base "/api/engine/v2/assets/:asset_id/instances/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:show]
    before_action :can_write, only: [:create, :update, :destroy]

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:show]

    before_action :ensure_json, only: [:create]

    getter current_instance : Model::AssetInstance { find_asset_inst }
    getter base_asset : Model::Asset { find_asset }

    def show
      render json: current_instance
    end

    def create
      model = Model::AssetInstance.from_json(self.body)

      if model.asset_id != base_asset.id
        render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "base asset_id does exist")
      else
        save_and_respond(model)
      end
    end

    def update
      current_instance.assign_attributes_from_json(self.body)
      save_and_respond(current_instance)
    end

    def destroy
      current_instance.destroy # expires the cache in after callback
      head :ok
    end

    # Helpers
    ###########################################################################

    protected def find_asset
      id = params["asset_id"]
      Log.context.set(control_system_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Asset.find!(id, runopts: {"read_mode" => "majority"})
    end

    protected def find_asset_inst
      id = params["id"]
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::AssetInstance.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
