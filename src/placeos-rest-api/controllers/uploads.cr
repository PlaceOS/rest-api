require "mime"
require "upload-signer"
require "placeos-models/storage"
require "placeos-models/upload"
require "xml"
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
      id : String,
    )
      unless @current_upload = ::PlaceOS::Model::Upload.find?(id)
        Log.warn { {message: "Invalid upload id. Unable to find matching upload entry", upload_id: id, authority: authority.id, user: current_user.id} }
        raise Error::NotFound.new("Invalid upload id: #{id}")
      end
    end

    @[AC::Route::Filter(:before_action, except: [:index])]
    def get_storage
      unless @storage = begin
               if upload = @current_upload
                 upload.storage
               else
                 ::PlaceOS::Model::Storage.storage_or_default(authority.id)
               end
             rescue ex
               Log.error(exception: ex) { {message: ex.message || "Authority storage configuration not found", authority_id: authority.id} }
               raise Error::NotFound.new(ex.message || "Authority storage configuration not found")
             end
      end
      @signer = UploadSigner.signer(UploadSigner::StorageType.from_value(storage.storage_type.value), storage.access_key, storage.decrypt_secret, storage.region, endpoint: storage.endpoint)
    end

    getter! authority : ::PlaceOS::Model::Authority?
    getter! storage : ::PlaceOS::Model::Storage?
    getter! signer : UploadSigner::Storage?
    getter! current_upload : ::PlaceOS::Model::Upload?

    # returns the list of uploads for current domain authority
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(description: "filters results to returns ones where file_name contains this search string", example: "my-file")]
      file_search : String? = nil,
      @[AC::Param::Info(description: "the maximum number of results to return", example: "10000")]
      limit : Int32 = 100,
      @[AC::Param::Info(description: "the starting offset of the result set. Used to implement pagination")]
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::Upload)
      table_name = ::PlaceOS::Model::Upload.table_name
      s = ::PlaceOS::Model::Storage.storage_or_default(authority.id)
      where = "WHERE u.storage_id = $1 "
      where += file_search.nil? ? "" : "AND u.file_name LIKE '%#{file_search}%'"

      uploads = ::PlaceOS::Model::Upload.find_all_by_sql(<<-SQL, s.id.as(String), limit, offset)
      WITH total AS (
        SELECT COUNT(u.*) AS total_count
        FROM "#{table_name}" u
        #{where}
      )
        SELECT u.*, t.total_count FROM "#{table_name}" u
        CROSS JOIN total t
        #{where}
        LIMIT $2 OFFSET $3;
      SQL

      return uploads if uploads.empty?

      total_rec = uploads.first.extra_attributes["total_count"].as(Int64)
      range_end = offset + (limit >= total_rec ? total_rec : limit) - 1
      response.headers["X-Total-Count"] = total_rec.to_s
      response.headers["Content-Range"] = "items #{offset}-#{range_end}/#{total_rec}"

      if range_end + 1 < total_rec
        query_params["offset"] = limit.to_s
        query_params["limit"] = limit.to_s
        response.headers["Link"] = %(<#{base_route}?#{query_params}>; rel="next")
      end

      uploads
    end

    # check the storage provider for a new file upload
    @[AC::Route::GET("/new")]
    def storage_name(
      @[AC::Param::Info(description: "Name of file which will be uploaded to cloud storage", example: "test.jpeg")]
      file_name : String,
      @[AC::Param::Info(description: "Size of file which will be uploaded to cloud storage", example: "1234")]
      file_size : Int64,
      @[AC::Param::Info(description: "Mime-Type of file which will be uploaded to cloud storage", example: "image/jpeg")]
      file_mime : String?,
    ) : NamedTuple(residence: String)
      allowed?(file_name, file_name)
      {residence: signer.name}
    end

    record UploadInfo, file_name : String, file_size : String, file_id : String, file_mime : String? = nil,
      file_path : String? = nil, permissions : ::PlaceOS::Model::Upload::Permissions = ::PlaceOS::Model::Upload::Permissions::None, public : Bool = true, expires : Int32 = 5 do
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

      if upload = ::PlaceOS::Model::Upload.find_by?(uploaded_by: user_id, file_name: file_name, file_size: info.file_size, file_md5: info.file_id)
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

        upload = ::PlaceOS::Model::Upload.create!(uploaded_by: user_id, uploaded_email: user_email, file_name: file_name, file_size: info.file_size, file_md5: info.file_id,
          file_path: info.file_path, storage_id: storage.id, permissions: info.permissions,
          object_key: object_key, object_options: object_options, public: info.public,
          resumable: signer.multipart?)

        {type: (signer.multipart? ? :chunked_upload : :direct_upload), signature: s3, upload_id: upload.id, residence: signer.name}
      end
    end

    protected def generate_temp_url(expiry : Int32 = TEMP_LINK_DEFAULT_MINUTES)
      max_expiry = TEMP_LINK_MAX_MINUTES
      expiry = expiry > max_expiry ? max_expiry : expiry
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

      us = UploadSigner.signer(UploadSigner::StorageType.from_value(storage.storage_type.value), storage.access_key, storage.decrypt_secret, storage.region, endpoint: storage.endpoint)
      us.get_object(storage.bucket_name, current_upload.object_key, expiry * 60)
    end

    # obtain a temporary link to a private resource
    @[AC::Route::GET("/:id/url")]
    def get_link(
      @[AC::Param::Info(description: "Link expiry period in minutes.", example: "60")]
      expiry : Int32 = TEMP_LINK_DEFAULT_MINUTES,
    )
      object_url = generate_temp_url(expiry)
      redirect_to object_url, status: :see_other
    end

    # proxy the data from the remote server
    #
    # this should not be used typically, it's only useful for dumb devices and firewall rules
    @[AC::Route::GET("/:id/download")]
    def download_proxy_file_contents
      object_url = generate_temp_url
      @__render_called__ = true

      HTTP::Client.get(object_url) do |upstream_response|
        # Set the response status code
        response.status_code = upstream_response.status_code

        # Copy headers from the upstream response, excluding 'Transfer-Encoding'
        upstream_response.headers.each do |key, value|
          response.headers[key] = value unless key.downcase == "transfer-encoding"
        end

        # Stream the response body directly to the client
        if body_io = upstream_response.body_io?
          IO.copy(body_io, response)
        else
          response.print upstream_response.body
        end
      end
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
      file_id : String?,
    ) : NamedTuple(
      type: Symbol,
      signature: NamedTuple(verb: String, url: String, headers: Hash(String, String)),
      upload_id: String | Nil, body: String | Nil)
      if (resumable_id = current_upload.resumable_id) && current_upload.resumable
        if part.strip == "finish"
          s3 = signer.commit_file(storage.bucket_name, current_upload.object_key, resumable_id, get_headers(current_upload))
          finish_body = nil
          if storage.storage_type == PlaceOS::Model::Storage::Type::Azure
            if part_data = current_upload.part_data
              block_ids = [] of String
              parts = part_data.keys.sort!
              parts.each do |ppart|
                block_ids << part_data[ppart].as_h["block_id"].as_s
              end
              finish_body = block_list_xml(block_ids)
            else
              raise AC::Route::Param::ValueError.new("missing part_data information. Required for AzureStorage")
            end
          end
          {type: :finish, signature: s3, upload_id: current_upload.id, body: finish_body}
        else
          unless md5 = file_id
            raise AC::Route::Param::ValueError.new("Missing MD5 hash of file part", "file_id", "required except for the `finish` part")
          end
          s3 = signer.set_part(storage.bucket_name, current_upload.object_key, current_upload.file_size, md5, part, resumable_id, get_headers(current_upload))
          {type: :part_upload, signature: s3, upload_id: current_upload.id, body: nil}
        end
      else
        raise AC::Route::Param::ValueError.new("upload is not resumable, no part available")
      end
    end

    record PartInfo, md5 : String, part : Int32, block_id : String? do
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
      info : UpdateInfo,
    ) : NamedTuple(
      type: Symbol,
      signature: NamedTuple(verb: String, url: String, headers: Hash(String, String)),
      upload_id: String | Nil, body: String | Nil) | NamedTuple(ok: Bool)
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
      id : String,
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
      rescue error : ::PlaceOS::Model::Error
        raise AC::Route::Param::ValueError.new(
          error.message,
          "file_name",
          storage.ext_filter.join(",")
        )
      end

      if mime = file_mime
        begin
          storage.check_file_mime(mime)
        rescue error : ::PlaceOS::Model::Error
          raise AC::Route::Param::ValueError.new(
            error.message,
            "file_mime",
            storage.mime_filter.join(",")
          )
        end
      end
    end

    private def block_list_xml(block_ids)
      XML.build(encoding: "UTF-8") do |xml|
        xml.element("BlockList") do
          block_ids.each do |tag|
            xml.element("Latest") { xml.text(tag) }
          end
        end
      end
    end
  end
end
