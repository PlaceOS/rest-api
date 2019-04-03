require "./application"

class Dependencies < Application
  base "/api/dependencies/"

  before_action :check_admin, except: [:index, :show]
  before_action :check_support, only: [:index, :show]
  before_action :find_dependency, only: [:show, :update, :destroy, :reload]

  @dep : Dependency?

  def index
    role = params[:role]
    elastic = Dependency.elastic
    query = elastic.query(params)

    if role && Dependency.ROLES.include?(role.to_sym)
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
    @dep = Dependency.create!(safe_params)
    save_and_respond dep
  end

  def destroy
    @dep.destroy!
    head :ok
  end

  ##
  # Additional Functions:
  ##
  # def reload
  #   depman = ::Orchestrator::DependencyManager.instance

  #   begin
  #     # Note:: Coroutine waiting for dependency load
  #     depman.load(@dep, :force).value
  #     content = nil
  #     status = :ok

  #     begin
  #       updated = 0

  #       @dep.modules.each do |mod|
  #         manager = mod.manager
  #         if manager
  #           updated += 1
  #           manager.reloaded(mod, code_update: true)
  #         end
  #       end

  #       content = {
  #         message: updated == 1 ? "#{updated} module updated" : "#{updated} modules updated",
  #       }.to_json
  #     rescue e
  #       # Let user know about any post reload issues
  #       message = "Warning! Reloaded successfully however some modules were not informed. It is safe to reload again.\nError was: #{e.message}\n#{e.backtrace.join("\n")}"
  #       status = :internal_server_error
  #       content = {
  #         message: message,
  #       }.to_json
  #     end

  #     render json: content, status: status
  #   rescue e : Exception
  #     msg = String.new(e.message)
  #     msg << "\n#{e.backtrace.join("\n")}" if e.respond_to?(:backtrace) && e.backtrace
  #     render plain: msg, status: :internal_server_error
  #     logger.error(msg)
  #   end
  # end

  protected DEP_PARAMS = [
    :name, :description, :role,
    :class_name, :module_name,
    :default, :ignore_connected,
  ]

  protected def safe_params
    settings = params[:settings]?
    args = params.to_h.select(DEP_PARAMS)
    args[:settings] = settings.to_unsafe_hash unless settings.nil?
    args
  end

  protected def find_dependency
    # Find will raise a 404 (not found) if there is an error
    @dep = Dependency.find!(params[:id])
  end
end
