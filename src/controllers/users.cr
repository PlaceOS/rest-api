require "oauth2"

require "./application"

module PlaceOS::Api
  class Users < Application
    include Utils::CurrentUser

    base "/api/engine/v2/users/"

    before_action :find_user, only: [:destroy, :update, :show]
    before_action :check_admin, only: [:index, :destroy, :create]
    before_action :check_authorization, only: [:update]

    before_action :ensure_json, only: [:update]

    getter user : Model::User?

    # Render the current user
    get("/current", :current) do
      render json: current_user.as_admin_json
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
      user = Model::User.new(params)
      user.authority = current_authority.as(Model::Authority)

      save_and_respond user
    end

    def update
      body = request.body.as(IO)
      user = @user.as(Model::User)

      if is_admin?
        user.assign_attributes_from_trusted_json(body)
      else
        user.assign_attributes_from_json(body)
      end

      save_and_respond user
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id" { update }

    #
    # Destroy user, revoke authentication.
    # TODO: Make this available when there is a clean up option for User
    # def destroy
    #   @user = User.find(id)
    #   if defined?(::UserCleanup)
    #     @user.destroy
    #     head :ok
    #   else
    #     ::Auth::Authentication.for_user(@user.id).each do |auth|
    #       auth.destroy
    #     end
    #     @user.destroy
    #   end
    # end

    protected def find_user
      user || (@user = Model::User.find!(params["id"]?))
    end

    protected def check_authorization
      # Does the current user have permission to perform the current action
      head :forbidden unless (find_user.try &.id) == current_user.id || is_admin?
    end
  end
end
