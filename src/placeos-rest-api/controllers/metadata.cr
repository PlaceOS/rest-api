require "promise"

require "./application"
require "../utilities/history"

module PlaceOS::Api
  class Metadata < Application
    include Utils::History

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

    getter metadata_id : String do
      route_params["metadata_id"]
    end

    getter name : String? do
      params["name"]?.presence
    end

    getter? include_parent : Bool do
      boolean_param("include_parent", default: true)
    end

    ###############################################################################################

    getter current_zone : Model::Zone { find_zone }

    getter current_metadata : Model::Metadata { find_metadata }

    ###############################################################################################

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

    def update
      metadata = Model::Metadata::Interface.from_json(self.body)

      # A name is required to lookup the metadata
      head :bad_request if metadata.name.empty?

      metadata = create_or_update(metadata)
      response, status = save_and_status(metadata)

      if status.ok? && response.is_a?(Model::Metadata)
        render json: Model::Metadata.interface(response), status: status
      else
        render json: response, status: status
      end
    end

    put_redirect

    def destroy
      if (metadata_name = name).nil?
        head :bad_request
      end

      Model::Metadata.for(parent_id, metadata_name).each &.destroy

      head :ok
    end

    # Returns the version history for a Settings model
    #
    # /:metadata_id/history
    model_history(current_metadata, :metadata_id)

    # Helpers
    ###########################################################################

    def create_or_update(metadata : Model::Metadata::Interface) : Model::Metadata
      if meta = Model::Metadata.for(parent_id, metadata.name).first?
        # Check if the current user has access
        if !is_support? && parent_id != user_token.id && (meta.editors & Set.new(user_token.user.roles)).empty?
          raise Error::Forbidden.new
        end

        # Only support+ users can edit the editors list
        if (editors = metadata.editors) && is_support?
          meta.editors = editors
        end

        # Update existing Metadata
        meta.description = metadata.description
        meta.details = metadata.details
        meta
      else
        # When creating a new metadata, must be at least a support user
        unless is_support? || parent_id == user_token.id
          raise Error::Forbidden.new
        end

        # Create new Metadata
        Model::Metadata.new(
          name: metadata.name,
          details: metadata.details,
          parent_id: parent_id,
          description: metadata.description,
          editors: metadata.editors || Set(String).new,
        )
      end.tap do |model|
        model.modified_by = current_user
      end
    end

    def find_metadata
      Log.context.set(metadata_id: metadata_id)
      # Find will raise a 404 (not found) if there is an error
      Model::Metadata.find!(metadata_id)
    end

    def find_zone
      Log.context.set(zone_id: parent_id)
      # Find will raise a 404 (not found) if there is an error
      Model::Zone.find!(parent_id)
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
