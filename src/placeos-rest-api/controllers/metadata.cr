require "promise"

require "./application"

module PlaceOS::Api
  class Metadata < Application
    base "/api/engine/v2/metadata"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :history]
    before_action :can_read_guest, only: [:show, :children_metadata]
    before_action :can_write, only: [:update, :destroy, :update_alt]

    # Callbacks
    ###############################################################################################

    before_action :check_delete_permissions, only: :destroy

    before_action :current_zone, only: :children

    before_action :body, only: [:update, :update_alt]

    # Params
    ###############################################################################################

    getter parent_id : String do
      route_params["id"]
    end

    getter name : String? do
      params["name"]?.presence
    end

    getter offset : Int32 do
      params["offset"]?.try(&.to_i?) || 0
    end

    getter limit : Int32 do
      params["limit"]?.try(&.to_i?) || 15
    end

    getter? include_parent : Bool do
      boolean_param("include_parent", default: true)
    end

    ###############################################################################################

    getter current_zone : Model::Zone do
      Log.context.set(zone_id: parent_id)
      # Find will raise a 404 (not found) if there is an error
      Model::Zone.find!(parent_id)
    end

    ###############################################################################################

    def index
      queries = query_params.compact_map do |key, value|
        Model::Metadata::Query.from_param?(key, value.presence)
      end

      results = Model::Metadata.query(queries)
      total = results.size

      # TODO: Add pagination to `Metadata#index`
      # range_start = offset
      # range_end = (results.size || 0) + range_start

      range_start = 0
      range_end = total

      response.headers["X-Total-Count"] = total.to_s
      response.headers["Content-Range"] = "metadata #{range_start}-#{range_end}/#{total}"

      if include_parent?
        render_json do |json|
          json.array do
            results.each &.to_parent_json(json)
          end
        end
      else
        render json: results
      end
    end

    # Fetch metadata for a model
    #
    # Filter for a specific metadata by name via `name` param
    def show
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        head :forbidden unless name && guest_ids.includes?(parent_id)
      end

      render json: Model::Metadata.build_metadata(parent_id, name)
    end

    record Children, zone : Model::Zone, metadata : Hash(String, Model::Metadata::Interface) do
      include JSON::Serializable

      def initialize(@zone, metadata_key : String?)
        @metadata = Model::Metadata.build_metadata(@zone, metadata_key)
      end
    end

    # Fetch metadata for Zone children
    #
    # Filter for a specific metadata by name via `name` param.
    # Includes the parent metadata by default via `include_parent` param.
    get "/:id/children", :children_metadata do
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        head :forbidden unless name && guest_ids.includes?(parent_id)
      end

      render_json do |json|
        json.array do
          current_zone.children.all.each do |zone|
            Children.new(zone, name).to_json(json) if include_parent? || zone.id != parent_id
          end
        end
      end
    end

    patch "/:id", :merge do
      mutate(merge: true)
    end

    put "/:id", :update do
      mutate(merge: false)
    end

    # Find (otherwise create) then update (or patch) the Metadata.
    protected def mutate(merge : Bool)
      metadata = Model::Metadata::Interface.from_json(self.body)

      # A name is required to lookup the metadata
      return head :bad_request if metadata.name.empty?

      metadata = create_or_update(metadata, merge: merge)
      response, status = save_and_status(metadata)

      if status.ok? && response.is_a?(Model::Metadata)
        render json: Model::Metadata.interface(response), status: status
      else
        render json: response, status: status
      end
    end

    def destroy
      if (metadata_name = name).nil?
        head :bad_request
      end

      Model::Metadata.for(parent_id, metadata_name).each &.destroy

      head :ok
    end

    # Returns the version history for a Settings model
    #
    get "/:id/history", :history do
      history = Model::Metadata.build_history(parent_id, name, offset: offset, limit: limit)

      total = Model::Metadata.for(parent_id, name).max_of?(&.history_count) || 0
      range_start = offset
      range_end = (history.max_of?(&.last.size) || 0) + range_start

      response.headers["X-Total-Count"] = total.to_s
      response.headers["Content-Range"] = "metadata #{range_start}-#{range_end}/#{total}"

      # Set link
      if range_end < total
        params["offset"] = (range_end + 1).to_s
        params["limit"] = limit.to_s
        path = File.join(base_route, "/#{parent_id}/history")
        response.headers["Link"] = %(<#{path}?#{query_params}>; rel="next")
      end

      render json: history
    end

    # Helpers
    ###########################################################################

    def create_or_update(interface : Model::Metadata::Interface, merge : Bool) : Model::Metadata
      if metadata = Model::Metadata.for(parent_id, interface.name).first?
        # Check if the current user has access
        raise Error::Forbidden.new unless metadata.user_can_update?(user_token)

        metadata.assign_from_interface(user_token, interface, merge)
      else
        # When creating a new metadata, must be at least a support user
        raise Error::Forbidden.new unless Model::Metadata.user_can_create?(interface.parent_id, user_token)

        # Create a new Metadata
        Model::Metadata.from_interface(interface).tap do |model|
          # Set `parent_id` in create
          model.parent_id = parent_id
        end
      end.tap do |model|
        model.modified_by = current_user
      end
    end

    # Fetch zones for system the current user has a role for
    def guest_ids
      sys_id = user_token.user.roles.last
      Model::ControlSystem.find!(sys_id, runopts: {"read_mode" => "majority"}).zones + [sys_id]
    end

    # Does the user making the request have permissions to modify the data
    def check_delete_permissions
      # NOTE: Will the user token ever be assigned a zone id?
      raise Error::Forbidden.new unless is_support? || parent_id == user_token.id
    end
  end
end
