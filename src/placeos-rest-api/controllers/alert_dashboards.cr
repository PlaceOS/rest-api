require "./application"

module PlaceOS::Api
  class AlertDashboards < Application
    include Utils::Permissions

    base "/api/engine/v2/alert_dashboards/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    ###############################################################################################

    @[AC::Route::Filter(:before_action)]
    def check_authority
      unless @authority = current_authority
        Log.warn { {message: "authority not found", action: "authorize!", host: request.hostname} }
        raise Error::Unauthorized.new "authority not found"
      end
    end

    getter! authority : ::PlaceOS::Model::Authority

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_alert_dashboard(id : String)
      Log.context.set(alert_dashboard_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_alert_dashboard = ::PlaceOS::Model::AlertDashboard.find!(id)
    end

    getter! current_alert_dashboard : ::PlaceOS::Model::AlertDashboard

    ###############################################################################################

    # list the alert dashboards
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return dashboards for a specific authority", example: "authority-1234")]
      authority_id : String? = nil,
    ) : Array(::PlaceOS::Model::AlertDashboard)
      elastic = ::PlaceOS::Model::AlertDashboard.elastic
      query = elastic.query(search_params)

      if authority_id
        query.filter({
          "authority_id" => [authority_id],
        })
      elsif !user_support?
        # Limit to current authority for non-support users
        query.filter({
          "authority_id" => [authority.id.as(String)],
        })
      end

      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # returns the details of an alert dashboard
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::AlertDashboard
      dashboard = current_alert_dashboard
      dashboard
    end

    # updates an alert dashboard
    @[AC::Route::PATCH("/:id", body: :dashboard)]
    @[AC::Route::PUT("/:id", body: :dashboard)]
    def update(dashboard : ::PlaceOS::Model::AlertDashboard) : ::PlaceOS::Model::AlertDashboard
      current = current_alert_dashboard
      current.assign_attributes(dashboard)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new alert dashboard
    @[AC::Route::POST("/", body: :dashboard, status_code: HTTP::Status::CREATED)]
    def create(dashboard : ::PlaceOS::Model::AlertDashboard) : ::PlaceOS::Model::AlertDashboard
      # Set authority_id if not provided
      if !dashboard.authority_id && !user_support?
        dashboard.authority_id = authority.id
      end

      raise Error::ModelValidation.new(dashboard.errors) unless dashboard.save
      dashboard
    end

    # removes an alert dashboard
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_alert_dashboard.destroy
    end

    # Get all alerts for a dashboard
    @[AC::Route::GET("/:id/alerts")]
    def alerts : Array(::PlaceOS::Model::Alert)
      alerts = current_alert_dashboard.alerts.to_a
      set_collection_headers(alerts.size, ::PlaceOS::Model::Alert.table_name)
      alerts
    end
  end
end
