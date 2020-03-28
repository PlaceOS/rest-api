require "promise"

require "./application"

module PlaceOS::Api
  class ZoneMetadata < Application
    include Utils::CoreHelper

    # NOTE:: this API shares the base zones route
    base "/api/engine/v2/zones/:id"

    before_action :check_support, only: [:update, :alt_update, :destroy]
    before_action :find_zone

    getter zone : Model::Zone?

    alias Metadata = NamedTuple(
      name: String?,
      description: String?,
      details: JSON::Any?,
      zone_id: String?)

    get "/metadata", :get_metadata do
      results = build_metadata(current_zone.metadata, params["name"]?)
      render json: results
    end

    get "/children/metadata", :get_children_metadata do
      filter = params["name"]?

      children = current_zone.children.to_a
      children.unshift(current_zone)

      results = [] of NamedTuple(
        zone: Model::Zone,
        metadata: Hash(String?, Metadata))

      children.each do |zone|
        results.push({
          zone:     zone,
          metadata: build_metadata(zone.metadata, filter),
        })
      end

      render json: results
    end

    post "/metadata", :update do
      metadata = Metadata.from_json(request.body.as(IO))

      # Metadata shouldn't be nil, use delete instead
      details = metadata[:details]
      head :bad_request unless details

      # We need a name to lookup the metadata
      name = metadata[:name]
      head :bad_request if name.nil? || name.empty?

      meta = current_zone.metadata.where(name: name).first?

      if meta
        # Update existing
        meta.description = metadata[:description]
        meta.details = details
      else
        # Create new
        meta = Model::Zone::Metadata.new
        meta.name = name
        meta.details = details
        meta.zone = current_zone
        meta.description = metadata[:description]
      end

      save_and_respond meta
    end

    put "/metadata", :alt_update { update }

    delete "/metadata", :destroy do
      name = params["name"]?
      head :bad_request unless name

      current_zone.metadata.where(name: name).each do |meta|
        meta.destroy
      end

      head :ok
    end

    # Helpers
    ###########################################################################

    def current_zone : Model::Zone
      zone || find_zone
    end

    def find_zone
      # Find will raise a 404 (not found) if there is an error
      @zone = Model::Zone.find!(params["id"]?)
    end

    def build_metadata(metadata, filter : String?)
      metadata = current_zone.metadata.where(name: filter) if filter

      metadata.each_with_object({} of String => Metadata) do |data, results|
        next if (name = data.name).nil?
        results[name] = {
          name:        data.name,
          description: data.description,
          details:     data.details,
          zone_id:     data.zone_id,
        }
      end
    end
  end
end
