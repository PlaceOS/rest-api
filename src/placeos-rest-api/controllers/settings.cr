require "./application"

module PlaceOS::Api
  class Settings < Application
    base "/api/engine/v2/settings/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
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

    getter offset : Int32 do
      params["offset"]?.try(&.to_i) || 0
    end

    getter limit : Int32 do
      params["limit"]?.try(&.to_i) || 15
    end

    ###############################################################################################

    getter current_settings : Model::Settings do
      id = params["id"]
      Log.context.set(settings_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Settings.find!(id, runopts: {"read_mode" => "majority"})
    end

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

    # Returns history for a particular Setting
    #
    get "/:id/history", :history do
      history = current_settings.history(offset: offset, limit: limit)

      # Privilege respecting decrypted settings history
      history.each &.decrypt_for!(current_user)

      total = Api::Settings.history_count(current_settings)
      range_start = offset
      range_end = history.size + range_start

      response.headers["X-Total-Count"] = total.to_s
      response.headers["Content-Range"] = "sets #{range_start}-#{range_end}/#{total}"

      # Set link
      if range_end < total
        params["offset"] = (range_end + 1).to_s
        params["limit"] = limit.to_s
        query_params = params.compact_map { |key, value| "#{key}=#{value}" unless key == "id" }.join("&")
        path = File.join(base_route, "/#{current_settings.id}/history")
        response.headers["Link"] = %(<#{path}?#{query_params}>; rel="next")
      end

      render json: history
    end

    # Helpers
    ###########################################################################

    # TODO: Optimise, get total query size from the response from rethinkdb
    def self.history_count(settings : Model::Settings) : Int32
      Model::Settings.table_query do |q|
        q
          .get_all([settings.parent_id.as(String)], index: :parent_id)
          .filter({settings_id: settings.id.as(String)})
          .count
      end.as_i
    end

    # Get an ordered hierarchy of Settings for the model
    #
    def self.collated_settings(user : Model::User, model : Model::ControlSystem | Model::Module)
      collated = model.settings_hierarchy.reverse!
      collated.each &.decrypt_for!(user)
      collated
    end
  end
end
