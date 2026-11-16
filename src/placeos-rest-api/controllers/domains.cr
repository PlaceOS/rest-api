require "./application"

module PlaceOS::Api
  # Domains (authorities), the tenants of this PlaceOS instance and their configuration
  class Domains < Application
    base "/api/engine/v2/domains/"

    # Delegated reads do not expose authentication secrets in internals.
    struct ReadOnlyDomain
      include JSON::Serializable
      include YAML::Serializable

      getter id : String?
      getter name : String
      getter description : String
      getter domain : String
      getter login_url : String
      getter logout_url : String
      getter config : Hash(String, JSON::Any)
      getter email_domains : Array(String)
      getter organisation_id : UUID?
      @[JSON::Field(converter: PlaceOS::Model::Timestamps::EpochConverter, type: "integer", format: "Int64")]
      getter created_at : Time
      @[JSON::Field(converter: PlaceOS::Model::Timestamps::EpochConverter, type: "integer", format: "Int64")]
      getter updated_at : Time

      def initialize(authority : ::PlaceOS::Model::Authority)
        @id, @name, @description, @domain = authority.id, authority.name, authority.description, authority.domain
        @login_url, @logout_url, @config = authority.login_url, authority.logout_url, authority.config
        @email_domains, @organisation_id = authority.email_domains, authority.organisation_id
        @created_at, @updated_at = authority.created_at, authority.updated_at
      end
    end

    alias DomainView = ::PlaceOS::Model::Authority | ReadOnlyDomain

    private def domain_view(authority : ::PlaceOS::Model::Authority) : DomainView
      may_manage_authority?(authority.id) ? authority : ReadOnlyDomain.new(authority)
    end

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
      domain = ::PlaceOS::Model::Authority.find!(id)
      ensure_reach!(domain)
      @current_domain = domain
    end

    getter! current_domain : ::PlaceOS::Model::Authority

    ###############################################################################################

    # list the domains
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "only rows owned by this organisation (must be within reach)", example: "0192f1c4-7a6b-7c4d-9f3e-1a2b3c4d5e6f")]
      organisation_id : UUID? = nil,
    ) : Array(DomainView)
      # PG full-text search (PPT-2644)
      query = narrow_organisation(scope_authorities(::PlaceOS::Model::Authority.all, "id"), organisation_id)
      paginate_search(query, ::PlaceOS::Model::Authority.table_name).map { |authority| domain_view(authority) }
    end

    # skip authentication for the lookup
    skip_action :authorize!, only: :lookup
    skip_action :set_user_id, only: :lookup

    # Find the domain name by looking into domain registerd email domains.
    @[AC::MCP(hide: true)]
    @[AC::Route::GET("/lookup/:email")]
    def lookup(
      @[AC::Param::Info(name: "email", description: "User email to lookup domain for", example: "user@domain.com")]
      email : String,
    ) : String
      authority = ::PlaceOS::Model::Authority.find_by_email(email)
      raise Error::NotFound.new("No matching domain found") unless authority
      authority.domain
    end

    # show the selected domain
    @[AC::Route::GET("/:id")]
    def show : DomainView
      domain_view(current_domain)
    end

    # udpate a domains details
    @[AC::Route::PATCH("/:id", body: :domain)]
    @[AC::Route::PUT("/:id", body: :domain)]
    def update(
      domain : ::PlaceOS::Model::Authority,
      @[AC::Param::Info(description: "the selected organisation; ownership cannot be changed while tenancy is enforced", example: "0192f1c4-7a6b-7c4d-9f3e-1a2b3c4d5e6f")]
      organisation_id : UUID? = nil,
    ) : ::PlaceOS::Model::Authority
      current = current_domain
      if domain.internals_assigned? || domain.domain_assigned? || domain.email_domains_assigned? || domain.login_url_assigned? || domain.logout_url_assigned?
        ensure_credential_management!(current.id)
      end
      current.assign_attributes(domain)
      if organisation_id && !Utils::Tenancy.enforce?
        check_cluster_admin
        current.organisation_id = organisation_id
      end
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new domain. Organisation admins create domains in their own
    # organisation; cluster admins name the organisation.
    @[AC::Route::POST("/", body: :domain, status_code: HTTP::Status::CREATED)]
    def create(
      domain : ::PlaceOS::Model::Authority,
      @[AC::Param::Info(description: "the organisation that owns the new domain", example: "0192f1c4-7a6b-7c4d-9f3e-1a2b3c4d5e6f")]
      organisation_id : UUID? = nil,
    ) : ::PlaceOS::Model::Authority
      domain.organisation_id = organisation_for_new_row(organisation_id)
      ensure_reach!(domain.organisation_id, "organisation", required: ::PlaceOS::Model::Permissions::Manage)
      raise Error::ModelValidation.new(domain.errors) unless domain.save
      domain
    end

    # remove a domain
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      ensure_credential_management!(current_domain.id)
      current_domain.destroy
    end
  end
end
