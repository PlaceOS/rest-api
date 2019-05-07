require "./application"

module Engine::API
  class Dependencies < Application
    base "/api/v1/dependencies/"

    # TODO: user access control
    # before_action :check_admin, except: [:index, :show]
    # before_action :check_support, only: [:index, :show]
    before_action :find_dependency, only: [:show, :update, :destroy]

    @dependency : Model::Dependency?
    getter dependency

    def index
      role = params[:role]
      elastic = Model::Dependency.elastic
      query = elastic.query(params)

      if role && Model::Dependency::Role.parse?(role)
        query.filter({
          "doc.role" => [role],
        })
      end

      query.sort = NAME_SORT_ASC
      render json: elastic.search(query)
    end

    def show
      render json: @dependency
    end

    def update
      dependency = @dependency
      return unless dependency

      args = params.to_h.reject(:role, :class_name)

      # Must destroy and re-add to change class or module type
      dependency.assign_attributes(args)
      save_and_respond(dependency)
    end

    def create
      body = request.body.not_nil!
      save_and_respond(Model::Dependency.from_json(body))
    end

    def destroy
      @dependency.try &.destroy
      head :ok
    end

    # Accepted HTTP params
    # :name
    # :description
    # :role
    # :class_name
    # :module_name
    # :default
    # :ignore_connected

    protected def find_dependency
      # Find will raise a 404 (not found) if there is an error
      @dependency = Model::Dependency.find!(params[:id]?)
    end
  end
end
