module Engine::API
  class Zones < Application
    base "/api/v1/zones/"

    # TODO: user access control
    # before_action :check_admin, except: [:index, :show]
    before_action :find_zone, only: [:show, :update, :destroy]

    def index
      query = Zone.elastic.query(params)
      query.sort = NAME_SORT_ASC

      if params.has_key? "tags"
        tags = params["tags"].gsub(/[^0-9a-z ]/i, "").split(/\s+/).reject(&.empty?).uniq
        return head :bad_request if tags.empty?

        query.must({
          "doc.tags" => tags,
        })
      else
        user = current_user
        return head :forbidden unless user && (user.support || user.sys_admin)
        query.search_field "doc.name"
      end

      render json: Zone.elastic.search(query)
    end

    def show
      if params.has_key? "data"
        key = params["data"]
        info_any = JSON.parse(@zone.settings)[key]?

        # convert setting string to Array or Hash
        info = info_any.try do |any|
          any.as_h? || any.as_a?
        end

        if info
          render json: info
        else
          head :not_found
        end
      else
        user = current_user
        return head :forbidden unless user && (user.support || user.sys_admin)
        if params.has_key? :complete
          # Include trigger data in response
          render json: @zone.attributes.merge!({:trigger_data => @zone.trigger_data})
        else
          render json: @zone
        end
      end
    end

    def update
      @zone.assign_attributes(safe_params.attributes)
      save_and_respond @zone
    end

    def create
      zone = Zone.new(safe_params.attributes)
      save_and_respond zone
    end

    def destroy
      @zone.destroy!
      head :ok
    end

    private class ZoneParams < Params
      attribute name : String
      attribute description : String
      attribute tags : Array(String)
      attribute triggers : Array(String)
      attribute settings : String
    end

    protected def safe_params
      ZoneParams.new(params).attributes
    end

    protected def find_zone
      # Find will raise a 404 (not found) if there is an error
      @zone = Zone.find!(params["id"]?)
    end
  end
end
