require "placeos-models/storage"
require "./application"

module PlaceOS::Api
  # File storage providers (e.g. S3) used for uploads
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
      ensure_resource_authority!(current_storage.authority_id, "storage", shared: true)
      authority_for_resource!(current_storage.authority_id, "storage") if Utils::Tenancy.enforce? && current_storage.authority_id
    end

    getter! current_storage : ::PlaceOS::Model::Storage

    # returns the list of available storages for provided authority
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "return storages which are in the authority provided", example: "auth-1234")]
      auth_id : String? = nil,
    ) : Array(::PlaceOS::Model::Storage)
      if Utils::Tenancy.enforce?
        authority_id = requested_resource_authority_id
        aliases = query_params.fetch_all("auth_id")
        if aliases.size > 1 || aliases.first?.try(&.empty?) || (auth_id && authority_id && auth_id != authority_id)
          raise Error::OrganisationSelection.new("provide one consistent authority_id or auth_id", "authority_invalid")
        end
        if selected = auth_id || authority_id
          ensure_authority_reach!(selected, "storage")
          ::PlaceOS::Model::Storage.where(authority_id: selected).to_a
        else
          shared = ::PlaceOS::Model::Storage.where(authority_id: nil).to_a
          if query_params["organisation_id"]?
            scope_resource_authorities(::PlaceOS::Model::Storage.all).to_a + shared
          else
            shared
          end
        end
      else
        ::PlaceOS::Model::Storage.where(authority_id: auth_id).all.to_a
      end
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
      owner = current.authority_id
      if Utils::Tenancy.enforce? && (requested = storage.authority_id) && requested != owner
        ensure_resource_authority!(requested, "storage")
        raise Error::Forbidden.new("storage ownership cannot be reassigned")
      end
      current.assign_attributes(storage)
      current.authority_id = owner if Utils::Tenancy.enforce?
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # adds a new storage
    @[AC::Route::POST("/", body: :storage, status_code: HTTP::Status::CREATED)]
    def create(storage : ::PlaceOS::Model::Storage) : ::PlaceOS::Model::Storage
      if Utils::Tenancy.enforce?
        storage.authority_id ||= resource_authority!.id
        ensure_resource_authority!(storage.authority_id, "storage")
      end
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
