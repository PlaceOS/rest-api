require "./application"

module Engine::API
  class Zones < Application
    base "/api/engine/v1/zones/"

    before_action :check_admin, except: [:index, :show]
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

        return head :bad_request if tags.empty?

        query.must({
          "tags" => tags,
        })
      else
        head :forbidden unless is_support? || is_admin?

        query.search_field "name"
      end

      render json: elastic.search(query)
    end

    def show
      zone = @zone.as(Model::Zone)
      if params.has_key? "data"
        key = params["data"]

        info = zone.get_setting_for(current_user, key)
        if info
          render json: info
        else
          head :not_found
        end
      else
        head :forbidden unless is_support? || is_admin?

        if params.has_key? "complete"
          # Include trigger data in response
          render json: with_fields(zone, {
            :trigger_data => zone.trigger_data,
          })
        else
          render json: zone
        end
      end
    end

    def update
      body = request.body.not_nil!
      zone = @zone.as(Model::Zone)

      zone.assign_attributes_from_json(body)
      save_and_respond zone
    end

    def create
      body = request.body.not_nil!
      zone = Model::Zone.from_json(body)
      save_and_respond zone
    end

    def destroy
      @zone.try &.destroy
      head :ok
    end

    def find_zone
      # Find will raise a 404 (not found) if there is an error
      @zone = Model::Zone.find!(params["id"]?)
    end
  end
end
