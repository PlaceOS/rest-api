require "./application"

module PlaceOS::Api
  class Schema < Application
    base "/api/engine/v2/schema/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_schema(id : String)
      Log.context.set(schema_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_schema = Model::JsonSchema.find!(id, runopts: {"read_mode" => "majority"})
    end

    getter! current_schema : Model::JsonSchema

    ###############################################################################################

    # return the list of schemas
    # schemas can be used to ensure metadata conforms to the desired state
    @[AC::Route::GET("/")]
    def index : Array(Model::JsonSchema)
      elastic = Model::JsonSchema.elastic
      query = elastic.query(search_params)
      paginate_results(elastic, query)
    end

    # return the details of a schema
    @[AC::Route::GET("/:id")]
    def show : Model::JsonSchema
      current_schema
    end

    # update a schema details
    @[AC::Route::PATCH("/:id", body: :schema)]
    @[AC::Route::PUT("/:id", body: :schema)]
    def update(schema : Model::JsonSchema) : Model::JsonSchema
      current = current_schema
      current.assign_attributes(schema)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new schema
    @[AC::Route::POST("/", body: :schema, status_code: HTTP::Status::CREATED)]
    def create(schema : Model::JsonSchema) : Model::JsonSchema
      raise Error::ModelValidation.new(schema.errors) unless schema.save
      schema
    end

    # remove a schema
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_schema.destroy
    end
  end
end
