require "placeos-models/partner"

require "./application"

module PlaceOS::Api
  # Partners: integrators that bring in and manage organisations, and the
  # management partner that is PlaceOS itself (PPT-526)
  class Partners < Application
    base "/api/engine/v2/partners/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    before_action :check_support, only: [:index, :show]
    before_action :check_cluster_admin, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_partner(id : UUID)
      Log.context.set(partner_id: id.to_s)
      partner = ::PlaceOS::Model::Partner.find!(id)
      unless tenancy.cluster? || tenancy.partner.try(&.id) == partner.id
        log_would_refuse("partner outside reach")
        raise Error::NotFound.new("partner not found") if Utils::Tenancy.enforce?
      end
      @current_partner_row = partner
    end

    getter! current_partner_row : ::PlaceOS::Model::Partner

    ###############################################################################################

    # cluster admins list every partner; everyone else sees their own
    @[AC::Route::GET("/")]
    def index : Array(::PlaceOS::Model::Partner)
      query = ::PlaceOS::Model::Partner.all
      unless tenancy.cluster?
        own = tenancy.partner.try(&.id)
        query = own ? query.where(id: own) : query.where("1 = ?", 0)
      end
      paginate_search(query, ::PlaceOS::Model::Partner.table_name)
    end

    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Partner
      current_partner_row
    end

    @[AC::Route::POST("/", body: :partner, status_code: HTTP::Status::CREATED)]
    def create(partner : ::PlaceOS::Model::Partner) : ::PlaceOS::Model::Partner
      raise Error::ModelValidation.new(partner.errors) unless partner.save
      partner
    end

    @[AC::Route::PATCH("/:id", body: :partner)]
    @[AC::Route::PUT("/:id", body: :partner)]
    def update(partner : ::PlaceOS::Model::Partner) : ::PlaceOS::Model::Partner
      current = current_partner_row
      current.assign_attributes(partner)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # Deletes are RESTRICTed by the database while organisations remain
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_partner_row.destroy
    end
  end
end
