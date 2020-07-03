require "promise"

require "./application"

module PlaceOS::Api
  class Metadata < Application
    # NOTE:: this API shares the base zones route
    base "/api/engine/v2/metadata"

    before_action :check_support, only: [:update, :update_alt, :destroy]
    before_action :find_zone, only: [:children]

    getter zone : Model::Zone?

    # Fetch metadata for a model
    #
    # Filter for a specific metadata by name via `name` param
    def show
      parent_id = params["id"]
      name = params["name"]?
      render json: Model::Metadata.build_metadata(parent_id, name)
    end

    # Fetch metadata for Zone children
    #
    # Filter for a specific metadata by name via `name` param
    get "/:id/children", :children_metadata do
      name = params["name"]?
      parent_id = current_zone.id

      results = current_zone.children.all.reject { |z| z.id == parent_id }.map do |zone|
        {
          zone:     zone,
          metadata: Model::Metadata.build_metadata(zone, name),
        }
      end

      render json: results.to_a
    end

    def update
      parent_id = params["id"]
      metadata = Model::Metadata::Interface.from_json(request.body.as(IO))

      # We need a name to lookup the metadata
      head :bad_request if metadata.name.empty?

      meta = Model::Metadata.for(parent_id, metadata.name).first?

      if meta
        # Update existing Metadata
        meta.description = metadata.description
        meta.details = metadata.details
      else
        # TODO: Check that the parent exists
        # Create new Metadata
        meta = Model::Metadata.new(
          name: metadata.name,
          details: metadata.details,
          parent_id: metadata.parent_id,
          description: metadata.description
        )
      end

      save_and_respond meta
    end

    put "/:id", :update_alt { update }

    def destroy
      parent_id = params["id"]
      name = params["name"]?
      head :bad_request unless name

      Model::Metadata.for(parent_id, name).each &.destroy

      head :ok
    end

    # Helpers
    ###########################################################################

    def current_zone : Model::Zone
      zone || find_zone
    end

    def find_zone
      id = params["id"]
      Log.context.set(zone_id: id)
      # Find will raise a 404 (not found) if there is an error
      @zone = Model::Zone.find!(id)
    end
  end
end
