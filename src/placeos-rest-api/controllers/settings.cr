require "./application"
require "../utilities/history"

module PlaceOS::Api
  class Settings < Application
    include Utils::History

    base "/api/engine/v2/settings"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :history]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :current_settings, only: [:show, :update, :update_alt, :destroy]
    before_action :body, only: [:create, :update, :update_alt]

    # Params
    ###############################################################################################

    getter parent_ids : Array(String)? do
      params["parent_id"]?.presence.try &.split(',').reject(&.empty?).uniq!
    end

    ###############################################################################################

    getter current_settings : Model::Settings { find_settings }

    ###############################################################################################

    def index
      if parents = parent_ids
        # Directly search for model's settings
        parent_settings = Model::Settings.for_parent(parents)
        # Decrypt for the user
        parent_settings.each &.decrypt_for!(current_user)

        render json: parent_settings
      else
        elastic = Model::Settings.elastic
        query = elastic.query(params)

        render json: paginate_results(elastic, query)
      end
    end

    def show
      render json: current_settings.decrypt_for!(current_user)
    end

    def update
      current_settings.assign_attributes_from_json(self.body)
      current_settings.modified_by = current_user

      save_and_respond(current_settings, &.decrypt_for!(current_user))
    end

    put_redirect

    def create
      new_settings = Model::Settings.from_json(self.body)
      new_settings.modified_by = current_user

      save_and_respond(new_settings, &.decrypt_for!(current_user))
    end

    def destroy
      current_settings.destroy
      head :ok
    end

    # Returns the version history for a Settings model
    #
    # /:id/history
    model_history(current_settings) do
      # Privilege respecting decrypted settings history
      history.tap(&.each(&.decrypt_for!(current_user)))
    end

    # Helpers
    ###########################################################################

    # Get an ordered hierarchy of Settings for the model
    #
    def self.collated_settings(user : Model::User, model : Model::ControlSystem | Model::Module)
      collated = model.settings_hierarchy.reverse!
      collated.each &.decrypt_for!(user)
      collated
    end

    protected def find_settings
      id = params["id"]
      Log.context.set(settings_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Settings.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
