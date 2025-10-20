require "./application"

module PlaceOS::Api
  class Alerts < Application
    include Utils::Permissions

    base "/api/engine/v2/alerts/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_alert(id : String)
      Log.context.set(alert_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_alert = ::PlaceOS::Model::Alert.find!(id)
    end

    getter! current_alert : ::PlaceOS::Model::Alert

    # extend the Alert model to include dashboard details
    class ::PlaceOS::Model::Alert
      @[JSON::Field(key: "alert_dashboard_details")]
      property alert_dashboard_details : ::PlaceOS::Model::AlertDashboard? = nil
    end

    ###############################################################################################

    # list the alerts
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return alerts for a specific dashboard", example: "alert_dashboard-1234")]
      alert_dashboard_id : String? = nil,
      @[AC::Param::Info(description: "filter by alert severity", example: "HIGH")]
      severity : String? = nil,
      @[AC::Param::Info(description: "filter by alert type", example: "THRESHOLD")]
      alert_type : String? = nil,
      @[AC::Param::Info(description: "filter by enabled status", example: "true")]
      enabled : Bool? = nil,
    ) : Array(::PlaceOS::Model::Alert)
      elastic = ::PlaceOS::Model::Alert.elastic
      query = elastic.query(search_params)

      if adi = alert_dashboard_id
        query.filter({
          "alert_dashboard_id" => [adi],
        })
      elsif !user_support?
        # Limit to current authority's dashboards for non-support users
        auth = current_authority.as(::PlaceOS::Model::Authority)
        dashboard_ids = ::PlaceOS::Model::AlertDashboard.where(authority_id: auth.id).select(:id).map(&.id.as(String))
        query.filter({
          "alert_dashboard_id" => dashboard_ids,
        })
      end

      if sev = severity
        query.filter({
          "severity" => [sev.downcase],
        })
      end

      if at = alert_type
        query.filter({
          "alert_type" => [at.downcase],
        })
      end

      if enb = enabled
        query.filter({
          "enabled" => [enb],
        })
      end

      p! query
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # returns the details of an alert
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "dashboard", description: "return the dashboard associated with this alert", example: "true")]
      include_dashboard : Bool? = nil,
    ) : ::PlaceOS::Model::Alert
      alert = current_alert
      alert.alert_dashboard_details = alert.alert_dashboard if include_dashboard
      alert
    end

    # updates an alert
    @[AC::Route::PATCH("/:id", body: :alert)]
    @[AC::Route::PUT("/:id", body: :alert)]
    def update(alert : ::PlaceOS::Model::Alert) : ::PlaceOS::Model::Alert
      current = current_alert
      current.assign_attributes(alert)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new alert
    @[AC::Route::POST("/", body: :alert, status_code: HTTP::Status::CREATED)]
    def create(alert : ::PlaceOS::Model::Alert) : ::PlaceOS::Model::Alert
      # Validate that the dashboard belongs to the current authority if not support user
      if alert.alert_dashboard_id && !user_support?
        dashboard = ::PlaceOS::Model::AlertDashboard.find!(alert.alert_dashboard_id.as(String))
        auth = current_authority.as(::PlaceOS::Model::Authority)
        unless dashboard.authority_id == auth.id
          raise Error::Forbidden.new("Cannot create alert for dashboard in different authority")
        end
      end

      raise Error::ModelValidation.new(alert.errors) unless alert.save
      alert
    end

    # removes an alert
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_alert.destroy
    end
  end
end
