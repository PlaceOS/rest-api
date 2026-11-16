require "./application"

module PlaceOS::Api
  # Alert dashboards, which group alerts for monitoring a set of systems
  class AlertDashboards < Application
    include Utils::Permissions

    base "/api/engine/v2/alert_dashboards/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:create])]
    def check_authority
      unless @authority = resource_authority
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
      @authority = Utils::Tenancy.enforce? ? authority_for_resource!(current_alert_dashboard.authority_id, "dashboard") : current_authority
    end

    getter! current_alert_dashboard : ::PlaceOS::Model::AlertDashboard

    ###############################################################################################

    # list the alert dashboards
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return dashboards for a specific authority", example: "authority-1234")]
      authority_id : String? = nil,
    ) : Array(::PlaceOS::Model::AlertDashboard)
      # PG full-text search (PPT-2644)
      query = ::PlaceOS::Model::AlertDashboard.all

      if Utils::Tenancy.enforce?
        query = scope_authorities(query)
        ensure_authority_reach!(authority_id, "dashboard") if authority_id
      end
      if authority_id
        query = query.where(authority_id: authority_id)
      elsif !Utils::Tenancy.enforce? && !user_support?
        # Limit to current authority for non-support users
        query = query.where(authority_id: resource_authority!.id.as(String))
      end

      paginate_search(query, ::PlaceOS::Model::AlertDashboard.table_name)
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
      owner = current.authority_id
      if Utils::Tenancy.enforce? && (requested = dashboard.authority_id) && requested != owner
        ensure_resource_authority!(requested, "dashboard")
        raise Error::Forbidden.new("dashboard ownership cannot be reassigned")
      end
      current.assign_attributes(dashboard)
      current.authority_id = owner if Utils::Tenancy.enforce?
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new alert dashboard
    @[AC::Route::POST("/", body: :dashboard, status_code: HTTP::Status::CREATED)]
    def create(dashboard : ::PlaceOS::Model::AlertDashboard) : ::PlaceOS::Model::AlertDashboard
      # Set authority_id if not provided
      if !user_support? || dashboard.authority_id.presence.nil?
        dashboard.authority_id = authority.id
      end

      ensure_resource_authority!(dashboard.authority_id, "dashboard")
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
