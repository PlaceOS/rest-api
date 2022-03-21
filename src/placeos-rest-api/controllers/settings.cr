require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Settings < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
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

    getter current_settings : Model::Settings { find_settings }

    @[OpenAPI(
      <<-YAML
        summary: get all settings
        security:
        - bearerAuth: []
      YAML
    )]
    def index
      param(parent_ids : String?, description: "filter by parent_id")
      if parents = parent_ids
        # Directly search for model's settings
        parent_settings = Model::Settings.for_parent(parents)
        # Decrypt for the user
        parent_settings.each &.decrypt_for!(current_user)

        render json: parent_settings
      else
        elastic = Model::Settings.elastic
        query = elastic.query(params)

        render json: paginate_results(elastic, query), type: Array(::PlaceOS::Model::Settings)
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: get current setting
        security:
        - bearerAuth: []
      YAML
    )]
    def show
      render json: current_settings.decrypt_for!(current_user), type: ::PlaceOS::Model::Settings
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a setting
        security:
        - bearerAuth: []
      YAML
    )]
    def update
      updated_settings = current_settings.assign_attributes_from_json(body_raw ::PlaceOS::Model::Settings)
      save_and_respond(updated_settings, &.decrypt_for!(current_user))
    end

    put_redirect

    @[OpenAPI(
      <<-YAML
        summary: Create a setting
        security:
        - bearerAuth: []
      YAML
    )]
    def create
      new_settings = body_as ::PlaceOS::Model::Settings, constructor: :from_json
      save_and_respond(new_settings, &.decrypt_for!(current_user))
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a setting
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
    def destroy
      current_settings.destroy
      head :ok
    end

    # Returns history for a particular Setting
    #
    get("/:id/history", :history, annotations: @[OpenAPI(<<-YAML
    summary: Get list of instances associated wtih given id of users based on email
    parameters:
      #{Schema.qp "limit", "The maximum number of history entries to return", type: "integer"}
      #{Schema.qp "offset", "Set offset", type: "integer"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
    YAML
    )]) do
      offset = params["offset"]?.try(&.to_i) || 0
      limit = params["limit"]?.try(&.to_i) || 15

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

    protected def find_settings
      id = params["id"]
      Log.context.set(settings_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Settings.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
