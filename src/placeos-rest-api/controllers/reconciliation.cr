require "./application"

module PlaceOS::Api
  # Preview and apply explicit cluster ownership repairs.
  class Reconciliation < Application
    base "/api/engine/v2/reconciliation"

    before_action :check_reconciliation_admin

    private def check_reconciliation_admin
      policy = Utils::Tenancy::Policy.new(user_token, current_authority.not_nil!.id.as(String), api_key_id: api_key.try(&.id))
      unless policy.valid? && policy.role.is_admin? && policy.scope.cluster?
        raise Error::Forbidden.new("ownership reconciliation requires a live cluster administrator")
      end
      access = action_name == :apply ? Access::Write : Access::Read
      unless policy.scope_access?({"reconciliation", "organisations"}, access)
        raise Error::Forbidden.new("reconciliation scope required")
      end
    end

    record Finding, resource_type : String, resource_id : String, organisation_id : UUID?, reason : String,
      related_type : String?, related_id : String?, related_organisation_id : UUID? do
      include JSON::Serializable
    end

    # List ownership conflicts and unowned estate.
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filter by model table name", example: "zone")]
      resource_type : String? = nil,
      @[AC::Param::Info(description: "filter by the resource ID", example: "zone-1234")]
      resource_id : String? = nil,
      @[AC::Param::Info(description: "maximum number of findings, up to 500", example: "100")]
      limit : Int32 = 100,
      @[AC::Param::Info(description: "zero-based result offset", example: "0")]
      offset : Int32 = 0,
    ) : Array(Finding)
      conditions = [] of String
      args = [] of String
      if resource_type
        args << resource_type
        conditions << "resource_type = $#{args.size}"
      end
      if resource_id
        args << resource_id
        conditions << "resource_id = $#{args.size}"
      end
      predicate = conditions.empty? ? "TRUE" : conditions.join(" AND ")
      results = [] of Finding
      PgORM::Database.with_connection do |db|
        total = db.query_one("SELECT count(*) FROM tenancy_ownership_conflicts WHERE #{predicate}", args: args, &.read(Int64))
        response.headers["X-Total-Count"] = total.to_s
        db.query_each(<<-SQL, args: args) do |rs|
          SELECT resource_type, resource_id, organisation_id, reason, related_type, related_id, related_organisation_id
          FROM tenancy_ownership_conflicts WHERE #{predicate}
          ORDER BY resource_type, resource_id, reason, related_type, related_id
          LIMIT #{limit.clamp(0, 500)} OFFSET #{offset.clamp(0, 1_000_000)}
          SQL
          results << Finding.new(rs.read(String), rs.read(String), rs.read(UUID?), rs.read(String), rs.read(String?), rs.read(String?), rs.read(UUID?))
        end
      end
      results
    end

    # Read the durable receipt of a completed ownership repair.
    @[AC::Route::GET("/:id")]
    def show(id : UUID) : JSON::Any
      json = PgORM::Database.with_connection do |db|
        db.query_one?(<<-SQL, args: [id.to_s], &.read(String))
          SELECT jsonb_build_object('id', id, 'actor_id', actor_id, 'authority_id', authority_id,
            'api_key_id', api_key_id, 'digest', digest, 'plan', plan, 'result', result, 'created_at', created_at)::text
          FROM tenancy_reconciliations WHERE id = $1::uuid
          SQL
      end
      raise Error::NotFound.new("reconciliation receipt not found") unless json
      JSON.parse(json)
    end

    record PreviewBody, operations : Array(Utils::Reconciliation::Operation) do
      include JSON::Serializable
    end

    record ApplyBody, operations : Array(Utils::Reconciliation::Operation), digest : String, idempotency_key : String do
      include JSON::Serializable
    end

    # Preview the complete ownership change without applying it.
    @[AC::MCP(behaviour: :read_only)]
    @[AC::Route::POST("/preview", body: :request)]
    def preview(request : PreviewBody) : Utils::Reconciliation::Preview
      on_primary { Utils::Reconciliation.preview(request.operations) }
    end

    # Apply an exact, conflict-free preview once.
    @[AC::Route::POST("/apply", body: :request)]
    def apply(request : ApplyBody) : JSON::Any
      Utils::Reconciliation.apply(request.operations, request.digest, request.idempotency_key,
        user_token.id, current_authority.not_nil!.id.as(String), api_key.try(&.id)) { check_reconciliation_admin }
    end
  end
end
