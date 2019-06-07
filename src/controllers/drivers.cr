require "./application"

module Engine::API
  class Drivers < Application
    base "/api/v1/drivers/"

    # TODO: user access control
    # before_action :check_admin, except: [:index, :show]
    # before_action :check_support, only: [:index, :show]

    before_action :find_driver, only: [:show, :update, :destroy]

    @driver : Model::Driver?
    getter :driver

    def index
      # Pick off role from HTTP params, render error if present and invalid
      role = params["role"]?.try &.to_i?.try do |r|
        parsed = Model::Driver::Role.from_value?(r)
        render status: :unprocessable_entity, text: "Invalid Role" unless parsed
        parsed
      end

      elastic = Model::Driver.elastic
      query = elastic.query(params)

      if role
        query.filter({
          "doc.role" => [role.to_i],
        })
      end

      query.sort(NAME_SORT_ASC)
      render json: elastic.search(query)
    end

    def show
      render json: @driver
    end

    def update
      driver = @driver.not_nil!
      body = request.body.not_nil!
      driver.assign_attributes_from_json(body)

      # Must destroy and re-add to change driver type
      render :unprocessable_entity, text: "Error: role must not change" if driver.role_changed?

      save_and_respond driver
    end

    def create
      body = request.body.not_nil!
      save_and_respond(Model::Driver.from_json(body))
    end

    def destroy
      @driver.try &.destroy
      head :ok
    end

    def find_driver
      # Find will raise a 404 (not found) if there is an error
      @driver = Model::Driver.find!(params["id"]?)
    end
  end
end
