require "promise"

require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Metadata < Application
    base "/api/engine/v2/metadata"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index]
    before_action :can_read_guest, only: [:show, :children_metadata]
    before_action :can_write, only: [:update, :destroy, :update_alt]

    # Callbacks
    ###############################################################################################

    before_action :check_delete_permissions, only: :destroy

    before_action :current_zone, only: :children

    before_action :body, only: [:update, :update_alt]

    # Params
    ###############################################################################################

    param_getter?(include_parent : Bool = true, "Include the parent metadata, by key of `parent_id`")

    getter parent_id : String do
      param(id : String)
    end

    param_getter(name : String?, "Filters by `name` key")

    ###############################################################################################

    getter current_zone : Model::Zone { find_zone }

    ###############################################################################################
    # Fetch metadata for a model
    #
    # Filter for a specific metadata by name via `name` param
    @[OpenAPI(
      <<-YAML
        summary: Fetch metadata for a model
        parameters:
          #{Schema.qp "id", "Parent ID of metadata", type: "string"}
          #{Schema.qp "name", "filter by name", type: "string"}
        security:
        - bearerAuth: []
        responses:
          403:
            description: Forbidden
          200:
            description: OK
            content:
              #{Schema.ref Model::Metadata}
      YAML
    )]
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
    get("/:id/children", :children_metadata, annotations: @[OpenAPI(<<-YAML
    summary: Fetch metadata for Zone children
    parameters:
    #{Schema.qp "include_parent", "Includes the parent metadata by default via `include_parent` param", type: "boolean"}
    #{Schema.qp "name", "filter by name", type: "string"}
    security:
    - bearerAuth: []
    responses:
      200:
        description: OK
        content:
          #{Schema.ref_array Model::Metadata}
    YAML
    )]) do
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        head :forbidden unless name && guest_ids.includes?(parent_id)
      end

      render_json do |json|
        json.array do
          current_zone.children.all.each do |child_zone|
            Children.new(child_zone, name).to_json(json) if include_parent? || child_zone.id != parent_id
          end
        end
      end
    end

    @[OpenAPI(
      <<-YAML
        summary: Update metadata
        requestBody:
          required: true
          content:
            #{Schema.ref Model::Metadata}
        security:
        - bearerAuth: []
        responses:
          400:
            description: Bad Request
          403:
            description: Forbidden
          200:
            description: OK
            content:
              #{Schema.ref Model::Metadata}
      YAML
    )]
    # ameba:disable Metrics/CyclomaticComplexity
    def update
      metadata = Model::Metadata::Interface.from_json(self.body)

      # We need a name to lookup the metadata
      head :bad_request if metadata.name.empty?

      meta = Model::Metadata.for(parent_id, metadata.name).first?

      # When creating, a new metadata, must be at least a support user
      # When updating, the user must contain a role within the metadata's editor roles
      unless is_support? || parent_id == user_token.id || (meta && (meta.editors & Set.new(user_token.user.roles)).size > 0)
        raise Error::Forbidden.new
      end

      if meta
        # only support+ users can edit the editors list
        editors = metadata.editors
        meta.editors = editors if editors && is_support?

        # Update existing Metadata
        meta.description = metadata.description
        meta.details = metadata.details
      else
        # TODO: Check that the parent exists
        # Create new Metadata
        meta = Model::Metadata.new(
          name: metadata.name,
          details: metadata.details,
          parent_id: parent_id,
          description: metadata.description,
          editors: metadata.editors || Set(String).new,
        )
      end

      response, status = save_and_status(meta)

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

    # Helpers
    ###########################################################################

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
