require "placeos-models/storage"
require "./application"

module PlaceOS::Api
  class Storages < Application
    base "/api/engine/v2/storages"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_storage(id : String)
      Log.context.set(storage_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_storage = ::PlaceOS::Model::Storage.find!(id)
    end

    getter! current_storage : ::PlaceOS::Model::Storage

    # returns the list of available storages for provided authority
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return storages which are in the authority provided", example: "auth-1234")]
      auth_id : String? = nil
    ) : Array(::PlaceOS::Model::Storage)
      ::PlaceOS::Model::Storage.where(authority_id: auth_id).all.to_a
    end

    # returns the details of a Storage
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Storage
      current_storage
    end

    # updates a storage details
    @[AC::Route::PATCH("/:id", body: :storage)]
    @[AC::Route::PUT("/:id", body: :storage)]
    def update(storage : ::PlaceOS::Model::Storage) : ::PlaceOS::Model::Storage
      current = current_storage
      current.assign_attributes(storage)
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new storage
    @[AC::Route::POST("/", body: :storage, status_code: HTTP::Status::CREATED)]
    def create(storage : ::PlaceOS::Model::Storage) : ::PlaceOS::Model::Storage
      raise Error::ModelValidation.new(storage.errors) unless storage.save
      storage
    end

    # removes a storage
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_storage.destroy # expires the cache in after callback
    end
  end
end
