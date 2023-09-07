require "mime"
require "upload-signer"
require "placeos-models/storage"
require "placeos-models/upload"
require "./application"

module PlaceOS::Api
  class Uploads < Application
    base "/api/engine/v2/uploads"

    @[AC::Route::Filter(:before_action)]
    def check_authority
      unless @authority = current_authority
        Log.warn { {message: "authority not found", action: "authorize!", host: request.hostname} }
        raise Error::Unauthorized.new "authority not found"
      end
    end

    @[AC::Route::Filter(:before_action, only: [:get_link, :edit, :update, :finished, :destroy])]
    def get_upload(
      @[AC::Param::Info(description: "upload id of the upload", example: "uploads-XXX")]
      id : String
    )
      unless @current_upload = Model::Upload.find?(id)
        Log.warn { {message: "Invalid upload id. Unable to find matching upload entry", upload_id: id, authority: authority.id, user: current_user.id} }
        raise Error::NotFound.new("Invalid upload id: #{id}")
      end
    end

    @[AC::Route::Filter(:before_action)]
    def get_storage
      unless @storage = begin
               if upload = @current_upload
                 upload.storage
               else
                 Model::Storage.storage_or_default(authority.id)
               end
             rescue ex
               Log.error(exception: ex) { {message: ex.message || "Authority storage configuration not found", authority_id: authority.id} }
               raise Error::NotFound.new(ex.message || "Authority storage configuration not found")
             end
      end
      @signer = UploadSigner::AmazonS3.new(storage.access_key, storage.decrypt_secret, storage.region, endpoint: storage.endpoint)
    end

    getter! authority : Model::Authority?
    getter! storage : Model::Storage?
    getter! signer : UploadSigner::AmazonS3?
    getter! current_upload : Model::Upload?

    # check the storage provider for a new file upload
    @[AC::Route::GET("/new")]
    def storage_name(
      @[AC::Param::Info(description: "Name of file which will be uploaded to cloud storage", example: "test.jpeg")]
      file_name : String,
      @[AC::Param::Info(description: "Size of file which will be uploaded to cloud storage", example: "1234")]
      file_size : Int64,
      @[AC::Param::Info(description: "Mime-Type of file which will be uploaded to cloud storage", example: "image/jpeg")]
      file_mime : String?
    ) : NamedTuple(residence: String)
      allowed?(file_name, file_name)
      {residence: signer.name}
    end

    record UploadInfo, file_name : String, file_size : String, file_id : String, file_mime : String? = nil,
      file_path : String? = nil, permissions : Model::Upload::Permissions = Model::Upload::Permissions::None, public : Bool = true, expires : Int32 = 5 do
      include JSON::Serializable

      def expires
        @expires * 60
      end

      def file_size
        @file_size.to_i64
      end

      def file_mime : String
        @file_mime || MIME.from_filename?(file_name) || "binary/octet-stream"
      end

      def user_mime : String?
        @file_mime
      end
    end

    # initiate a new upload
    @[AC::Route::POST("/", body: :info)]
    def create(info : UploadInfo) : NamedTuple(
      type: Symbol,
      signature: NamedTuple(verb: String, url: String, headers: Hash(String, String)),
      part_list: Array(Int32),
      part_data: Hash(String, JSON::Any),
      upload_id: String | Nil,
      residence: String) | NamedTuple(
      type: Symbol,
      signature: NamedTuple(verb: String, url: String, headers: Hash(String, String)),
      upload_id: String | Nil,
      residence: String)
      user_id = current_user.id
      user_email = current_user.email
      file_name = sanitize_filename(info.file_name)

      if upload = Model::Upload.find_by?(uploaded_by: user_id, file_name: file_name, file_size: info.file_size, file_md5: info.file_id)
        visibility = upload.public ? :public : :private
        resp = if (resumable_id = upload.resumable_id) && upload.resumable
                 s3 = signer.get_parts(storage.bucket_name, upload.object_key, upload.file_size, resumable_id, get_headers(upload))
                 {type: :parts, signature: s3, part_list: upload.part_list, part_data: upload.part_data}
               else
                 s3 = signer.sign_upload(storage.bucket_name, upload.object_key, upload.file_size, upload.file_md5, info.file_mime,
                   visibility, info.expires, get_headers(upload))
                 {type: (signer.multipart? ? :chunked_upload : :direct_upload), signature: s3}
               end

        resp.merge({upload_id: upload.id, residence: signer.name})
      else
        allowed?(info.file_name, info.user_mime)

        object_key = get_object_key(file_name)
        object_options = default_object_options(info.file_mime, info.public)
        visibility = info.public ? :public : :private
        s3 = signer.sign_upload(storage.bucket_name, object_key, info.file_size, info.file_id, info.file_mime, visibility, info.expires, get_default_headers(info.file_mime, info.public))

        upload = Model::Upload.create!(uploaded_by: user_id, uploaded_email: user_email, file_name: file_name, file_size: info.file_size, file_md5: info.file_id,
          file_path: info.file_path, storage_id: storage.id, permissions: info.permissions,
          object_key: object_key, object_options: object_options, public: info.public,
          resumable: signer.multipart?)

        {type: (signer.multipart? ? :chunked_upload : :direct_upload), signature: s3, upload_id: upload.id, residence: signer.name}
      end
    end

    # obtain a temporary link to a private resource
    @[AC::Route::GET("/:id/url")]
    def get_link(
      @[AC::Param::Info(description: "Link expiry period in minutes.", example: "60")]
      expiry : Int32 = 1440
    )
      expiry = expiry > 1440 ? 1440 : expiry
      unless storage = current_upload.storage
        Log.warn { {message: "upload object associated storage not found", upload_id: current_upload.id, authority: authority.id, user: current_user.id} }
        raise Error::NotFound.new("Upload missing associated storage")
      end

      unless current_upload.public
        case current_upload.permissions
        when .admin?   then check_admin
        when .support? then check_support
        end
      end

      s3 = UploadSigner::AmazonS3.new(storage.access_key, storage.decrypt_secret, storage.region, endpoint: storage.endpoint)
      object_url = s3.get_object(storage.bucket_name, current_upload.object_key, expiry * 60)

      redirect_to object_url, status: :see_other
    end

    # obtain a signed request for each chunk of the file being uploaded.
    #
    # once all parts are uploaded, you can obtain the final commit request by passing `?part=finish`
    # file_id is required except for the final finish request
    @[AC::Route::GET("/:id/edit")]
    def edit(
      @[AC::Param::Info(description: "file part which will be uploaded to cloud storage", example: "part1")]
      part : String,
      @[AC::Param::Info(description: "MD5 of the part which will be uploaded to cloud storage", example: "pxdXsOVpn6+SAcvZoZQphQ==")]
      file_id : String?
    ) : NamedTuple(
      type: Symbol,
      signature: NamedTuple(verb: String, url: String, headers: Hash(String, String)),
      upload_id: String | Nil)
      if (resumable_id = current_upload.resumable_id) && current_upload.resumable
        if part.strip == "finish"
          s3 = signer.commit_file(storage.bucket_name, current_upload.object_key, resumable_id, get_headers(current_upload))
          {type: :finish, signature: s3, upload_id: current_upload.id}
        else
          unless md5 = file_id
            raise AC::Route::Param::ValueError.new("Missing MD5 hash of file part", "file_id", "required except for the `finish` part")
          end
          s3 = signer.set_part(storage.bucket_name, current_upload.object_key, current_upload.file_size, md5, part, resumable_id, get_headers(current_upload))
          {type: :part_upload, signature: s3, upload_id: current_upload.id}
        end
      else
        raise AC::Route::Param::ValueError.new("upload is not resumable, no part available")
      end
    end

    record PartInfo, md5 : String, part : Int32 do
      include JSON::Serializable
    end

    record UpdateInfo, file_id : String?, part : Int32?, resumable_id : String?,
      part_data : Array(PartInfo)?, part_list : Array(Int32)?, part_update : Bool? do
      include JSON::Serializable
    end

    # save your resumable upload progress and grab the next signed request
    @[AC::Route::PATCH("/:id", body: info)]
    def update(
      @[AC::Param::Info(description: "the next file part which we need a signed URL for", example: "part2")]
      part : String?,
      @[AC::Param::Info(description: "MD5 of the next part", example: "pxdXsOVpn6+SAcvZoZQphQ==")]
      file_id : String?,
      info : UpdateInfo
    ) : NamedTuple(
      type: Symbol,
      signature: NamedTuple(verb: String, url: String, headers: Hash(String, String)),
      upload_id: String | Nil) | NamedTuple(ok: Bool)
      raise AC::Route::Param::ValueError.new("upload is not resumable") unless current_upload.resumable

      if part_list = info.part_list
        current_upload.part_list = part_list
        if pdata = info.part_data
          pdata.each do |p|
            current_upload.part_data[p.part.to_s] = JSON.parse(p.to_json)
          end
          current_upload.part_data_changed
        end
      end

      current_upload.resumable_id = info.resumable_id if info.resumable_id
      current_upload.save!

      # returns the signed URL for the next part if params are provided
      if part && file_id
        edit(part, file_id)
      elsif !info.part_update
        edit(info.part.to_s, info.file_id)
      else
        {ok: true}
      end
    end

    # mark an upload as complete
    @[AC::Route::PUT("/:id")]
    def finished : NamedTuple(ok: Bool)
      current_upload.update!(upload_complete: true)
      {ok: true}
    end

    # delete an uploaded file
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy(
      @[AC::Param::Info(description: "upload id of the upload", example: "uploads-XXX")]
      id : String
    ) : Nil
      signer.delete_file(storage.bucket_name, current_upload.object_key, current_upload.resumable_id)
      current_upload.destroy
    end

    private def sanitize_filename(filename)
      filename = filename.gsub(/^.*(\\|\/)/, "") # get only the filename (just in case)
      filename = filename.gsub(/[^\w\.\-]/, '_') # replace all non alphanumeric or periods with underscore
      filename
    end

    private def get_headers(upload)
      if h = upload.object_options["headers"]?.try &.as_h?
        h.transform_values(&.as_s)
      else
        {} of String => String
      end
    end

    private def get_object_key(filename)
      "/#{request.hostname}/#{Time.utc.to_unix_f.to_s.sub(".", "")}#{rand(1000)}#{File.extname(filename)}"
    end

    private def default_object_options(file_mime, public)
      if mime = file_mime
        {
          "permissions" => JSON::Any.new(public ? "public" : "private"),
          "headers"     => JSON::Any.new({
            "Content-Type" => JSON::Any.new(mime),
          }),
        }
      else
        {"permissions" => JSON::Any.new(public ? "public" : "private")}
      end
    end

    private def get_default_headers(mime, public)
      opts = default_object_options(mime, public)
      if h = opts["headers"]?.try &.as_h?
        h.transform_values(&.as_s)
      else
        {} of String => String
      end
    end

    def allowed?(file_name, file_mime)
      if !Model::Upload.safe_filename?(file_name)
        raise AC::Route::Param::ValueError.new(
          "filename contains unsupported characters or words",
          "file_name"
        )
      end

      begin
        storage.check_file_ext(File.extname(file_name))
      rescue error : PlaceOS::Model::Error
        raise AC::Route::Param::ValueError.new(
          error.message,
          "file_name",
          storage.ext_filter.join(",")
        )
      end

      if mime = file_mime
        begin
          storage.check_file_mime(mime)
        rescue error : PlaceOS::Model::Error
          raise AC::Route::Param::ValueError.new(
            error.message,
            "file_mime",
            storage.mime_filter.join(",")
          )
        end
      end
    end
  end
end
