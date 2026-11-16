require "placeos-models/organisation"
require "placeos-models/partner"

require "./application"

module PlaceOS::Api
  # Organisations: the customers that own domains and estate (PPT-526)
  class Organisations < Application
    base "/api/engine/v2/organisations/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show, :current]
    before_action :can_write, only: [:create, :update, :destroy, :claim]

    before_action :check_cluster_admin, only: [:create, :update, :destroy, :claim]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create, :current])]
    def find_current_organisation(id : UUID)
      Log.context.set(organisation_id: id.to_s)
      organisation = ::PlaceOS::Model::Organisation.find!(id)
      ensure_discoverable_organisation!(organisation.id)
      @current_organisation_row = organisation
    end

    getter! current_organisation_row : ::PlaceOS::Model::Organisation

    ###############################################################################################

    # Minimal selector records; billing and private configuration stay in
    # the administrative write responses, not discovery.
    struct Summary
      include JSON::Serializable
      include YAML::Serializable

      getter id : UUID?
      getter name : String
      getter partner_id : UUID?
      getter? partner_staff : Bool

      def initialize(organisation : ::PlaceOS::Model::Organisation)
        @id = organisation.id
        @name = organisation.name
        @partner_id = organisation.partner_id
        @partner_staff = organisation.partner_staff
      end
    end

    struct PartnerSummary
      include JSON::Serializable
      include YAML::Serializable

      getter id : UUID?
      getter name : String

      def initialize(partner : ::PlaceOS::Model::Partner)
        @id = partner.id
        @name = partner.name
      end
    end

    record CurrentReach,
      reach : String,
      enforcing : Bool,
      organisation : Summary?,
      partner : PartnerSummary?,
      organisations : Array(Summary)?,
      selection_required : Bool,
      selected_organisation_id : UUID? do
      include JSON::Serializable
    end

    # Describe the caller's home organisation and accessible organisations.
    @[AC::Route::GET("/current")]
    def current : CurrentReach
      scope = resolved_tenancy
      organisations = scope.organisation_ids.try do |ids|
        ids.empty? ? [] of Summary : ::PlaceOS::Model::Organisation.find_all(ids.to_a).order("name, id").map { |org| Summary.new(org) }.to_a
      end
      selected = if query_params["organisation_id"]?
                   selected_organisation_id
                 elsif scope.reach.organisation?
                   current_organisation.try(&.id)
                 end
      CurrentReach.new(
        reach: scope.reach.to_s.downcase,
        enforcing: Utils::Tenancy.enforce?,
        organisation: scope.organisation.try { |org| Summary.new(org) },
        partner: scope.partner.try { |partner| PartnerSummary.new(partner) },
        organisations: organisations,
        selection_required: Utils::Tenancy.enforce? && !scope.reach.organisation?,
        selected_organisation_id: selected,
      )
    end

    # List accessible organisations for the REST organisation selector.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "only organisations under this partner", example: "0192f1c4-7a6b-7c4d-9f3e-1a2b3c4d5e6f")]
      partner_id : UUID? = nil,
    ) : Array(Summary)
      query = ::PlaceOS::Model::Organisation.all
      query = query.where(partner_id: partner_id) if partner_id
      if ids = resolved_tenancy.organisation_ids
        list = ids.to_a.map(&.to_s)
        query = list.empty? ? query.where("1 = ?", 0) : query.where("id = ANY(ARRAY[#{list.join(", ") { "?" }}]::uuid[])", list)
      end
      paginate_search(query, ::PlaceOS::Model::Organisation.table_name).map { |org| Summary.new(org) }
    end

    # Get an accessible organisation's selector details.
    @[AC::Route::GET("/:id")]
    def show : Summary
      Summary.new(current_organisation_row)
    end

    # `payer` and `partner_staff` are not mass-assignable, so they travel as
    # parameters
    @[AC::Route::POST("/", body: :organisation, status_code: HTTP::Status::CREATED)]
    def create(
      organisation : ::PlaceOS::Model::Organisation,
      @[AC::Param::Info(description: "who is invoiced: partner or organisation", example: "partner")]
      payer : String? = nil,
      @[AC::Param::Info(description: "true for the partner's own staff organisation", example: "false")]
      partner_staff : Bool? = nil,
    ) : ::PlaceOS::Model::Organisation
      organisation.payer = payer if payer
      organisation.partner_staff = partner_staff unless partner_staff.nil?
      raise Error::ModelValidation.new(organisation.errors) unless organisation.save
      organisation
    end

    @[AC::Route::PATCH("/:id", body: :organisation)]
    @[AC::Route::PUT("/:id", body: :organisation)]
    def update(
      organisation : ::PlaceOS::Model::Organisation,
      @[AC::Param::Info(description: "who is invoiced: partner or organisation", example: "partner")]
      payer : String? = nil,
      @[AC::Param::Info(description: "true for the partner's own staff organisation", example: "false")]
      partner_staff : Bool? = nil,
    ) : ::PlaceOS::Model::Organisation
      current = current_organisation_row
      current.assign_attributes(organisation)
      current.payer = payer if payer
      current.partner_staff = partner_staff unless partner_staff.nil?
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # Deletes are RESTRICTed by the database while anything is owned
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_organisation_row.destroy
    end

    record ClaimBody, zone_ids : Array(String) do
      include JSON::Serializable
    end

    record ClaimResult, zones : Int64, systems : Int64, modules : Int64, triggers : Int64 do
      include JSON::Serializable
    end

    # Assigns unowned zone trees to the organisation: the zones named, their
    # descendants, the systems in those zones and the modules of those
    # systems. Rows already owned by another organisation are left alone.
    @[AC::Route::POST("/:id/claim", body: :body)]
    def claim(body : ClaimBody) : ClaimResult
      organisation_id = current_organisation_row.id.as(UUID).to_s
      roots = body.zone_ids.uniq
      return ClaimResult.new(0, 0, 0, 0) if roots.empty?

      PgORM::Database.connection do |db|
        zones = db.exec(<<-SQL, args: [roots, organisation_id]).rows_affected
          WITH RECURSIVE tree AS (
            SELECT id FROM zone WHERE id = ANY($1::text[])
            UNION
            SELECT z.id FROM zone z INNER JOIN tree t ON z.parent_id = t.id
          )
          UPDATE zone SET organisation_id = $2::uuid
          WHERE id IN (SELECT id FROM tree) AND organisation_id IS NULL
          SQL
        systems = db.exec(<<-SQL, args: [organisation_id]).rows_affected
          UPDATE sys SET organisation_id = $1::uuid
          WHERE organisation_id IS NULL
            AND EXISTS (SELECT 1 FROM zone z WHERE z.id = ANY(sys.zones) AND z.organisation_id = $1::uuid)
            AND NOT EXISTS (SELECT 1 FROM zone z WHERE z.id = ANY(sys.zones) AND z.organisation_id IS NOT NULL AND z.organisation_id <> $1::uuid)
          SQL
        modules = db.exec(<<-SQL, args: [organisation_id]).rows_affected
          UPDATE mod SET organisation_id = $1::uuid
          WHERE organisation_id IS NULL
            AND (
              control_system_id IN (SELECT id FROM sys WHERE organisation_id = $1::uuid)
              OR EXISTS (SELECT 1 FROM sys s WHERE mod.id = ANY(s.modules) AND s.organisation_id = $1::uuid)
            )
            AND NOT EXISTS (SELECT 1 FROM sys s WHERE mod.id = ANY(s.modules) AND s.organisation_id IS NOT NULL AND s.organisation_id <> $1::uuid)
          SQL
        triggers = db.exec(<<-SQL, args: [organisation_id]).rows_affected
          UPDATE trigger SET organisation_id = $1::uuid
          WHERE organisation_id IS NULL
            AND control_system_id IN (SELECT id FROM sys WHERE organisation_id = $1::uuid)
          SQL
        ClaimResult.new(zones, systems, modules, triggers)
      end
    end
  end
end
