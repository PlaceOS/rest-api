require "../application"
require "upload-signer"

module PlaceOS::Api
  class PlaylistMedia < Application
    include Utils::Permissions

    base "/api/engine/v2/signage/media"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_item(id : String)
      Log.context.set(item_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_item = item = ::PlaceOS::Model::Playlist::Item.find!(id)

      # ensure the current user has access
      raise Error::Forbidden.new unless authority.id == item.authority_id
    end

    getter! current_item : ::PlaceOS::Model::Playlist::Item

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :item_update)]
    def parse_update_item(@item_update : ::PlaceOS::Model::Playlist::Item)
    end

    getter! item_update : ::PlaceOS::Model::Playlist::Item

    getter authority : ::PlaceOS::Model::Authority { current_authority.as(::PlaceOS::Model::Authority) }

    # Permissions
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:destroy, :update, :create])]
    def check_access_level
      return if user_support?

      # find the org zone
      org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id

      access = check_access(current_user.groups, [org_zone_id])
      return if access.can_manage?

      raise Error::Forbidden.new
    end

    ###############################################################################################

    # list media items uploaded for this domain
    @[AC::Route::GET("/")]
    def index : Array(::PlaceOS::Model::Playlist::Item)
      elastic = ::PlaceOS::Model::Playlist::Item.elastic
      query = elastic.query(search_params)
      query.filter({
        "authority_id" => [authority.id.as(String)],
      })
      query.search_field "name"
      query.sort({"created_at" => {order: :desc}})
      paginate_results(elastic, query)
    end

    # return the details of the requested media item
    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::Playlist::Item
      current_item
    end

    # update the details of a media item
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : ::PlaceOS::Model::Playlist::Item
      item = item_update
      current = current_item
      current.assign_attributes(item)
      current.authority_id = authority.id
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new media item
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : ::PlaceOS::Model::Playlist::Item
      item = item_update
      item.authority_id = authority.id
      raise Error::ModelValidation.new(item.errors) unless item.save
      item
    end

    # remove a media item from the library
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      PgORM::Database.transaction do |_tx|
        {current_item.media, current_item.thumbnail}.each do |upload|
          next unless upload

          storage = upload.storage || ::PlaceOS::Model::Storage.storage_or_default(authority.id)
          signer = UploadSigner::AmazonS3.new(storage.access_key, storage.decrypt_secret, storage.region, endpoint: storage.endpoint)
          signer.delete_file(storage.bucket_name, upload.object_key, upload.resumable_id)
          upload.destroy
        end
        current_item.destroy
      end
    end
  end
end
