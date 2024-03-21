require "./application"

module PlaceOS::Api
  class ShortURL < Application
    include Utils::Permissions

    base "/api/engine/v2/short_url"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_url(id : String)
      Log.context.set(url_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_url = url = Model::Shortener.find!(id)

      # ensure the current user has access
      raise Error::Forbidden.new unless authority.id == url.authority_id
    end

    getter! current_url : Model::Shortener

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :url_update)]
    def parse_update_url(@url_update : Model::Shortener)
    end

    getter! url_update : Model::Shortener

    getter authority : Model::Authority { current_authority.as(Model::Authority) }

    # Permissions
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:destroy, :update, :create])]
    def check_access_level
      return if user_support?

      # find the org zone
      org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id

      access = check_access(current_user.groups, [org_zone_id])
      return if access.can_manage?

      raise Error::Forbidden.new
    end

    ###############################################################################################

    # list the short URLs for this domain
    @[AC::Route::GET("/")]
    def index : Array(Model::Shortener)
      elastic = Model::Shortener.elastic
      query = elastic.query(search_params)
      query.filter({
        "authority_id" => [authority.id.as(String)],
      })
      query.search_field "name"
      query.sort({"created_at" => {order: :desc}})
      paginate_results(elastic, query)
    end

    # return the details of the requested shortened URL
    @[AC::Route::GET("/:id")]
    def show : Model::Shortener
      current_url
    end

    # update the details of a short URL
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : Model::Shortener
      url = url_update
      current = current_url
      current.assign_attributes(url)
      current.authority_id = authority.id
      current.user = current_user
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new short URL
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : Model::Shortener
      url = url_update
      url.authority_id = authority.id
      url.user = current_user
      raise Error::ModelValidation.new(url.errors) unless url.save
      url
    end

    # remove a short URL
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_url.destroy
    end
  end
end
