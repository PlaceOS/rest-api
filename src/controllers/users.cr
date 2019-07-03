require "oauth2"

require "./application"

module Engine::API
  class Users < Application
    include Utils::CurrentUser
    include Utils::CurrentAuthority
    base "/api/v1/users/"

    before_action :find_user, only: [:destroy, :update, :create]
    before_action :check_admin, only: [:index, :destroy, :create]
    before_action :check_authorization, only: [:update]

    before_action :ensure_json, only: [:update]

    @user : Model::User?

    # Render the current user
    get("/current", :current) do
      render json: current_user
    end

    def index
      elastic = Model::User.elastic
      query = elastic.query(params)

      query.must_not({"deleted" => [true]})

      authority_id = params["authority_id"]?
      query.filter({"authority_id" => [authority_id]}) if authority_id

      results = elastic.search(query)[:results].map &.as_admin_json

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
      user.authority = current_authority.not_nil!
      save_and_respond user
    end

    def update
      body = request.body.not_nil!
      user = @user.not_nil!

      if is_admin?
        user.assign_attributes_from_trusted_json(body)
      else
        user.assign_attributes_from_json(body)
      end

      save_and_respond user
    end

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
      @user = Model::User.find!(params["id"]?) unless @user
    end

    protected def check_authorization
      find_user unless @user

      # Does the current user have permission to perform the current action
      head :forbidden unless (@user.try &.id) == current_user.id || is_admin?
    end
  end
end
