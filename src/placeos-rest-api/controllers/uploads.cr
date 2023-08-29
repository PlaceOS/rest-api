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

    @[AC::Route::Filter(:before_action, only: [:get_link, :edit, :update, :destroy])]
    def get_upload
      id = params["upload_id"]? || params["id"]?
      raise AC::Route::Param::MissingError.new("missing required parameter", "upload_id", "String") unless id
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

    @[AC::Route::GET("/new")]
    def index(
      @[AC::Param::Info(description: "Name of file which will be uploaded to cloud storage", example: "test.jpeg")]
      file_name : String,
      @[AC::Param::Info(description: "Size of file which will be uploaded to cloud storage", example: "1234")]
      file_size : Int64,
      @[AC::Param::Info(description: "Mime-Type of file which will be uploaded to cloud storage", example: "image/jpeg")]
      file_mime : String?
    )
      allowed?(file_name, file_name)
      render json: {residence: signer.name}
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

    @[AC::Route::POST("/", body: :info)]
    def create(info : UploadInfo)
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

        render json: resp.merge({upload_id: upload.id, residence: signer.name})
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

        render json: {type: (signer.multipart? ? :chunked_upload : :direct_upload), signature: s3, upload_id: upload.id, residence: signer.name}
      end
    end

    @[AC::Route::GET("/:id/url")]
    def get_link(
      @[AC::Param::Info(description: "upload id of the upload", example: "uploads-XXX")]
      id : String,
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
      response.headers["Location"] = s3.get_object(storage.bucket_name, current_upload.object_key, expiry * 60)
      render status: 303
    end

    @[AC::Route::GET("/:id/edit")]
    def edit(
      @[AC::Param::Info(description: "file part which will be uploaded to cloud storage", example: "part1")]
      part : String,
      @[AC::Param::Info(description: "MD5 of file which will be uploaded to cloud storage", example: "pxdXsOVpn6+SAcvZoZQphQ==")]
      file_id : String?
    )
      if (resumable_id = current_upload.resumable_id) && current_upload.resumable
        if part.strip == "finish"
          s3 = signer.commit_file(storage.bucket_name, current_upload.object_key, resumable_id, get_headers(current_upload))
          render json: {type: :finish, signature: s3, upload_id: current_upload.id}
        else
          unless md5 = file_id
            return render json: "Missing file_id parameter", status: :not_acceptable
          end
          s3 = signer.set_part(storage.bucket_name, current_upload.object_key, current_upload.file_size, md5, part, resumable_id, get_headers(current_upload))
          render json: {type: :part_upload, signature: s3, upload_id: current_upload.id}
        end
      else
        render status: :not_acceptable
      end
    end

    record PartInfo, md5 : String, part : Int32 do
      include JSON::Serializable
    end

    record UpdateInfo, file_id : String?, part : Int32?, resumable_id : String?,
      part_data : Array(PartInfo)?, part_list : Array(Int32)?, part_update : Bool? do
      include JSON::Serializable
    end

    @[AC::Route::PUT("/:id")]
    def update(
      @[AC::Param::Info(description: "upload id of the upload", example: "uploads-XXX")]
      id : String,
      part : Int32?,
      file_id : String?,
      file_mime : String?
    )
      upload_info = if (body = request.body.try &.gets_to_end) && (body.strip('"') != "{}")
                      UpdateInfo.from_json(body)
                    else
                      nil
                    end

      if info = upload_info
        if current_upload.resumable
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

          if (pu = info.part_update) && pu
            render json: {ok: true}, status: :ok
          else
            edit((part || info.part).to_s, file_id || info.file_id)
          end
        else
          render status: :not_acceptable
        end
      else
        current_upload.update!(upload_complete: true)
        render json: {ok: true}, status: :ok
      end
    end

    @[AC::Route::DELETE("/:id")]
    def destroy(
      @[AC::Param::Info(description: "upload id of the upload", example: "uploads-XXX")]
      id : String
    )
      signer.delete_file(storage.bucket_name, current_upload.object_key, current_upload.resumable_id)
      current_upload.destroy
      render json: {ok: true}, status: :ok
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
      storage.check_file_ext(File.extname(file_name)[1..])
      if mime = file_mime
        storage.check_file_mime(mime)
      end
    rescue ex : PlaceOS::Model::Error
      Log.error(exception: ex) { {file_name: file_name, mime_type: file_mime} }
      raise Error::Unauthorized.new(ex.message || "Invalid file extension or mime type")
    end
  end
end
