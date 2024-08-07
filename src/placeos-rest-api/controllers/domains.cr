require "./application"

module PlaceOS::Api
  class Domains < Application
    base "/api/engine/v2/domains/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show, :lookup]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :lookup, :create])]
    def find_current_domain(id : String)
      Log.context.set(authority_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_domain = ::PlaceOS::Model::Authority.find!(id)
    end

    getter! current_domain : ::PlaceOS::Model::Authority

    ###############################################################################################

    # list the domains
    @[AC::Route::GET("/")]
    def index : Array(::PlaceOS::Model::Authority)
      elastic = ::PlaceOS::Model::Authority.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # skip authentication for the lookup
    skip_action :authorize!, only: :lookup
    skip_action :set_user_id, only: :lookup

    # Find the domain name by looking into domain registerd email domains.
    @[AC::Route::GET("/lookup/:email")]
    def lookup(
      @[AC::Param::Info(name: "email", description: "User email to lookup domain for", example: "user@domain.com")]
      email : String
    ) : String
      authority = ::PlaceOS::Model::Authority.find_by_email(email)
      raise Error::NotFound.new("No matching domain found") unless authority
      authority.domain
    end

    # show the selected domain
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Authority
      current_domain
    end

    # udpate a domains details
    @[AC::Route::PATCH("/:id", body: :domain)]
    @[AC::Route::PUT("/:id", body: :domain)]
    def update(domain : ::PlaceOS::Model::Authority) : ::PlaceOS::Model::Authority
      current = current_domain
      current.assign_attributes(domain)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new domain
    @[AC::Route::POST("/", body: :domain, status_code: HTTP::Status::CREATED)]
    def create(domain : ::PlaceOS::Model::Authority) : ::PlaceOS::Model::Authority
      raise Error::ModelValidation.new(domain.errors) unless domain.save
      domain
    end

    # remove a domain
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_domain.destroy
    end
  end
end
