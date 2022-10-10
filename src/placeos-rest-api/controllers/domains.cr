require "./application"

module PlaceOS::Api
  class Domains < Application
    base "/api/engine/v2/domains/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_domain(id : String)
      Log.context.set(authority_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_domain = Model::Authority.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_domain : Model::Authority

    ###############################################################################################

    # list the domains
    @[AC::Route::GET("/")]
    def index : Array(Model::Authority)
      elastic = Model::Authority.elastic
      query = elastic.query(search_params)
      query.sort(NAME_SORT_ASC)
      paginate_results(elastic, query)
    end

    # show the selected domain
    @[AC::Route::GET("/:id")]
    def show : Model::Authority
      current_domain
    end

    # udpate a domains details
    @[AC::Route::PATCH("/:id", body: :domain)]
    @[AC::Route::PUT("/:id", body: :domain)]
    def update(domain : Model::Authority) : Model::Authority
      current = current_domain
      current.assign_attributes(domain)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new domain
    @[AC::Route::POST("/", body: :domain, status_code: HTTP::Status::CREATED)]
    def create(domain : Model::Authority) : Model::Authority
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
