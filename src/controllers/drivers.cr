require "./application"

module PlaceOS::Api
  class Drivers < Application
    base "/api/engine/v2/drivers/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :find_driver, only: [:show, :update, :update_alt, :destroy, :recompile]

    @driver : Model::Driver?

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
          "role" => [role.to_i],
        })
      end

      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_driver
    end

    def update
      driver = current_driver
      driver.assign_attributes_from_json(request.body.as(IO))

      # Must destroy and re-add to change driver type
      render :unprocessable_entity, text: "Error: role must not change" if driver.role_changed?

      save_and_respond driver
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::Driver.from_json(request.body.as(IO)))
    end

    def destroy
      current_driver.destroy
      head :ok
    end

    post "/:id/recompile", :recompile do
      driver = current_driver
      commit = driver.commit.not_nil!
      if commit.starts_with?("RECOMPILE")
        head :already_reported
      else
        driver.commit = "RECOMPILE-#{commit}"
        save_and_respond driver
      end
    end

    #  Helpers
    ###########################################################################

    def current_driver : Model::Driver
      @driver || find_driver
    end

    def find_driver
      # Find will raise a 404 (not found) if there is an error
      @driver = Model::Driver.find!(params["id"], runopts: {"read_mode" => "majority"})
    end
  end
end
