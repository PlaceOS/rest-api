require "oauth2"

require "./application"

module PlaceOS::Api
  class Users < Application
    include Utils::CurrentUser

    base "/api/engine/v2/users/"

    before_action :find_user, only: [:destroy, :update, :show]
    before_action :check_admin, only: [:index, :destroy, :create]
    before_action :check_authorization, only: [:update, :update_alt]

    before_action :ensure_json, only: [:update, :update_alt]

    getter user : Model::User?

    # Render the current user
    get("/current", :current) do
      begin
        render json: current_user.as_admin_json
      rescue e : RethinkORM::Error::DocumentNotFound
        head :unauthorized
      end
    end

    def index
      elastic = Model::User.elastic
      query = elastic.query(params)

      query.must_not({"deleted" => [true]})

      authority_id = params["authority_id"]?
      query.filter({"authority_id" => [authority_id]}) if authority_id

      results = paginate_results(elastic, query).map &.as_admin_json
      render json: results
    end

    def show
      # We only want to provide limited "public" information
      if is_admin?
        render json: @user.try &.as_admin_json
      else
        render json: @user.try &.as_public_json
      end
    end

    def create
      user = Model::User.from_json(request.body.as(IO))
      # allow sys-admins to create users on other domains
      user.authority ||= current_authority.as(Model::Authority)

      save_and_respond user
    end

    def update
      user = @user.as(Model::User)

      # Ensure authority doesn't change
      authority_id = user.authority_id
      user.assign_attributes_from_json(request.body.as(IO))
      user.authority_id = authority_id

      save_and_respond user
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    # Destroy user, revoke authentication.
    def destroy
      @user.try &.destroy
      head :ok
    end

    protected def find_user
      id = params["id"]
      Log.context.set(user_id: id)

      user || (@user = Model::User.find!(id, runopts: {"read_mode" => "majority"}))
    end

    protected def check_authorization
      # Does the current user have permission to perform the current action
      head :forbidden unless (find_user.try &.id) == current_user.id || is_admin?
    end
  end
end
