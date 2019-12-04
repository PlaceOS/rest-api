require "./application"

module ACAEngine::Api
  class Zones < Application
    base "/api/engine/v2/zones/"

    before_action :check_admin, except: [:index]
    before_action :check_support, except: [:index]
    before_action :find_zone, only: [:show, :update, :destroy]

    @zone : Model::Zone?
    getter :zone

    def index
      elastic = Model::Zone.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      if params.has_key? "tags"
        # list of unique tags
        tags = params["tags"].gsub(/[^0-9a-z ]/i, "").split(/\s+/).reject(&.empty?).uniq

        head :bad_request if tags.empty?

        query.must({
          "tags" => tags,
        })
      else
        head :forbidden unless is_support? || is_admin?

        query.search_field "name"
      end

      render json: elastic.search(query)
    end

    # BREAKING CHANGE: param key `data` used to attempt to retrieve a setting from the zone
    def show
      if params.has_key? "complete"
        # Include trigger data in response
        render json: with_fields(current_zone, {
          :trigger_data => current_zone.trigger_data,
        })
      else
        render json: current_zone
      end
    end

    def update
      current_zone.assign_attributes_from_json(request.body.as(IO))
      save_and_respond current_zone
    end

    def create
      save_and_respond Model::Zone.from_json(request.body.as(IO))
    end

    def destroy
      current_zone.destroy
      head :ok
    end

    # # TODO: Module in zone exec
    # post("/:id/exec/:module_slug/:method") do
    #   module_slug, method = params["module_slug"], params["method"]
    # end

    # Helpers
    ###########################################################################

    def current_zone : Model::Zone
      return @zone.as(Model::Zone) if @zone
      find_zone
    end

    def find_zone
      # Find will raise a 404 (not found) if there is an error
      @zone = Model::Zone.find!(params["id"]?)
    end
  end
end
