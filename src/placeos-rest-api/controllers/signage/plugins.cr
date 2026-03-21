require "../application"

module PlaceOS::Api
  class SignagePlugins < Application
    include Utils::Permissions

    base "/api/engine/v2/signage/plugins"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_plugin(id : String)
      Log.context.set(plugin_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_plugin = plugin = ::PlaceOS::Model::SignagePlugin.find!(id)

      # shared plugins (no authority_id) are accessible to all, otherwise must match
      if plugin_authority = plugin.authority_id
        raise Error::Forbidden.new unless authority.id == plugin_authority
      end
    end

    getter! current_plugin : ::PlaceOS::Model::SignagePlugin

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :plugin_update)]
    def parse_update_plugin(@plugin_update : ::PlaceOS::Model::SignagePlugin)
    end

    getter! plugin_update : ::PlaceOS::Model::SignagePlugin

    getter authority : ::PlaceOS::Model::Authority { current_authority.as(::PlaceOS::Model::Authority) }

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

    # list signage plugins for this domain and shared plugins (no authority)
    @[AC::Route::GET("/")]
    def index : Array(::PlaceOS::Model::SignagePlugin)
      authority_id = authority.id.as(String)

      elastic = ::PlaceOS::Model::SignagePlugin.elastic
      query = elastic.query(search_params)
      query.should({
        "authority_id" => [authority_id, nil],
      })
      query.minimum_should_match(1)
      query.search_field "name"
      query.sort(NAME_SORT_ASC)

      # ES can't express "field = X OR field IS NULL" in a single should clause,
      # so we fetch authority-scoped results from ES and merge shared plugins from PG
      paginate_results(elastic, query)
    end

    # return the details of the requested signage plugin
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::SignagePlugin
      current_plugin
    end

    # update the details of a signage plugin
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::SignagePlugin
      plugin = plugin_update
      current = current_plugin
      current.assign_attributes(plugin)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new signage plugin
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::SignagePlugin
      plugin = plugin_update
      raise Error::ModelValidation.new(plugin.errors) unless plugin.save
      plugin
    end

    # remove a signage plugin
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_plugin.destroy
    end
  end
end
