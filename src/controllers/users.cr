require "oauth2"

require "./application"

module Engine::API
  class Users < Application
    include Utils::CurrentUser
    include Utils::CurrentAuthority
    base "/api/v1/users/"

    # before_action :check_authorization, only: [:update]
    # before_action :check_admin, only: [:index, :destroy, :create]

    before_action :ensure_json, only: [:update]

    # Factored into seperate auth service
    # Replaced with a JWT
    # before_action :doorkeeper_authorize!

    # Render the current user
    get("/current", :current) do
      render json: current_user.not_nil!
    end

    def index
      elastic = Model::User.elastic
      query = elastic.query(params)

      query.must_not({"deleted" => [true]})

      authority_id = params["authority_id"]?
      query.filter({"authority_id" => [authority_id]}) if authority_id

      results = elastic.search(query)[:results].map do |user|
        user.as_admin_json
      end

      render json: results
    end

    def show
      user = current_user.not_nil!

      # We only want to provide limited "public" information
      if user.sys_admin
        render json: user.as_admin_json
      else
        render json: user.as_public_json
      end
    end

    def create
      user = Model::User.new(params)
      user.authority = current_authority.not_nil!
      save_and_respond user
    end

    ##
    # Requests requiring authorization have already loaded the model
    def update
      user = current_user.not_nil!
      body = request.body.not_nil!

      if user.sys_admin
        user.assign_attributes_from_trusted_json(body)
      else
        user.assign_attributes_from_json(body)
      end

      save_and_respond user
    end

    # # Make this available when there is a clean up option
    # TODO: Offlocaded to auth service? or here
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

    # TODO: Are these concerns satisified through mass asignment restrictions?
    # protected def safe_params(params)
    #   user = required_params(params, :user)
    #   if current_user.sys_admin
    #     user.select!(
    #       :name, :first_name, :last_name, :country, :building, :email, :phone, :nickname,
    #       :card_number, :login_name, :staff_id, :sys_admin, :support, :password, :password_confirmation
    #     )
    #   else
    #     user.select!(
    #       :name, :first_name, :last_name, :country, :building, :email, :phone, :nickname
    #     )
    #   end
    # end

    def check_authorization
      # Find will raise a 404 (not found) if there is an error
      # @user = User.find!(params["id"]?)

      # FIXME: previously, current_user pulled off manager
      # Likely new middleware will decode user from jwt

      @user = Model::User.find(params["id"])
      user = current_user.not_nil!

      # Does the current user have permission to perform the current action
      head :forbidden unless @user.id == user.id || user.sys_admin
    end
  end
end
