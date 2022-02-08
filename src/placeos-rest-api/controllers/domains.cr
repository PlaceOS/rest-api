require "./application"

require "openapi-generator"
require "openapi-generator/helpers/action-controller"

module PlaceOS::Api
  class Domains < Application
    include ::OpenAPI::Generator::Controller
    include ::OpenAPI::Generator::Helpers::ActionController
    base "/api/engine/v2/domains/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy, :remove, :update_alt]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    # Callbacks
    ###############################################################################################

    before_action :current_domain, only: [:show, :update, :update_alt, :destroy]
    before_action :body, only: [:create, :update, :update_alt]

    ###############################################################################################

    getter current_domain : Model::Authority { find_domain }

    @[OpenAPI(
      <<-YAML
        summary: get all domains
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref_array Domain}
      YAML
    )]
    def index
      elastic = Model::Authority.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    @[OpenAPI(
      <<-YAML
        summary: get current domain
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Model::Domain}
      YAML
    )]
    def show
      render json: current_domain
    end

    @[OpenAPI(
      <<-YAML
        summary: Update a domain
        requestBody:
          required: true
          content:
            #{Schema.ref Model::Domain}
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
            content:
              #{Schema.ref Model::Domain}
      YAML
    )]
    def update
      current_domain.assign_attributes_from_json(self.body)
      save_and_respond current_domain
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put("/:id", :update_alt, annotations: @[OpenAPI(<<-YAML
      summary: Update a domain
      requestBody:
        required: true
        content:
          #{Schema.ref Model::Domain}
      security:
      - bearerAuth: []
      responses:
        200:
          description: OK
          content:
            #{Schema.ref Model::Domain}
      YAML
    )]) { update }

    @[OpenAPI(
      <<-YAML
        summary: Create a domain
        requestBody:
          required: true
          content:
            #{Schema.ref Model::Domain}
        security:
        - bearerAuth: []
        responses:
          201:
            description: OK
            content:
              #{Schema.ref Model::Domain}
      YAML
    )]
    def create
      save_and_respond(Model::Authority.from_json(self.body))
    end

    @[OpenAPI(
      <<-YAML
        summary: Delete a domain
        security:
        - bearerAuth: []
        responses:
          200:
            description: OK
      YAML
    )]
    def destroy
      current_domain.destroy
      head :ok
    end

    #  Helpers
    ###########################################################################

    protected def find_domain
      id = params["id"]
      Log.context.set(authority_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Authority.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
