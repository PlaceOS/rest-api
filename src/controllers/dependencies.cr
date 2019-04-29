require "./application"

module Engine::API
  class Dependencies < Application
    base "/api/v1/dependencies/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]
    before_action :find_dependency, only: [:show, :update, :destroy, :reload]

    @dep : Dependency?

    def index
      role = params[:role]
      elastic = Dependency.elastic
      query = elastic.query(params)

      if role && Dependency::Roles.parse?(role)
        query.filter({
          "doc.role" => [role],
        })
      end

      query.sort = NAME_SORT_ASC
      render json: elastic.search(query)
    end

    def show
      render json: @dep
    end

    def update
      args = params.reject(:role, :class_name)

      # Must destroy and re-add to change class or module type
      @dep.assign_attributes(args)
      save_and_respond @dep
    end

    def create
      @dep = Dependency.create!(params)
      save_and_respond dep
    end

    def destroy
      @dep.destroy!
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
      @dep = Dependency.find!(params[:id]?)
    end
  end
end
