require "./application"

module PlaceOS::Api
  class AssetInstances < Application
    base "/api/engine/v2/zones/:zone_id/assets/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index] # , :show]
    # before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    # before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index] # , :show]

    # before_action :ensure_json, only: [:create]

    getter current_asset_inst : Model::AssetInstance { find_asset_inst }
    getter current_zone : Model::Zone { find_zone }

    def index
      elastic = Model::Asset.elastic
      puts "params are: #{params}"
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      render json: paginate_results(elastic, query)
    end

    def update
      current_asset_inst.assign_attributes_from_json(self.body)
      save_and_respond(current_asset_inst)
    end

    def create
      model = Model::AssetInstance.from_json(self.body)

      if model.zone_id != current_zone.id
        render_error(HTTP::Status::UNPROCESSABLE_ENTITY, "zone_id mismatch")
      else
        save_and_respond(model)
      end
    end

    def destroy
      current_asset_inst.destroy # expires the cache in after callback
      head :ok
    end

    # Helpers
    ###########################################################################

    protected def find_asset
      id = params["id"]
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Asset.find!(id) # , runopts: {"read_mode" => "majority"})
    end

    protected def find_zone
      id = params["zone_id"]
      Log.context.set(control_system_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Zone.find!(id, runopts: {"read_mode" => "majority"})
    end

    protected def find_asset_inst
      id = params["id"]
      Log.context.set(asset_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::AssetInstance.find!(id) # , runopts: {"read_mode" => "majority"})
    end
  end
end
