require "digest/md5"
require "upload-signer"
require "placeos-models/storage"
require "placeos-models/upload"

module PlaceOS::Api
  # Writes bytes the server already holds into a domain's object storage
  # through the same `Storage` and `Upload` machinery the uploads controller
  # uses: records the row, signs a PUT, sends the bytes with the signature
  # headers verbatim, then marks the row complete.
  module ObjectStore
    def self.signer_for(storage : ::PlaceOS::Model::Storage) : UploadSigner::Storage
      UploadSigner.signer(
        UploadSigner::StorageType.from_value(storage.storage_type.value),
        storage.access_key,
        storage.decrypt_secret,
        storage.region,
        endpoint: storage.endpoint,
      )
    end

    # a unique key for a new object, namespaced by the domain
    def self.object_key(hostname : String?, file_name : String) : String
      "/#{hostname}/#{Time.utc.to_unix_f.to_s.sub(".", "")}#{rand(1000)}#{File.extname(file_name)}"
    end

    def self.put(
      bytes : Bytes,
      mime : String,
      storage : ::PlaceOS::Model::Storage,
      user : ::PlaceOS::Model::User,
      file_name : String,
      object_key : String,
      public : Bool = false,
      tags : Array(String) = [] of String,
    ) : ::PlaceOS::Model::Upload
      put(bytes, mime, storage, user.id.as(String), user.email.to_s, file_name, object_key, public, tags)
    end

    def self.put(
      bytes : Bytes,
      mime : String,
      storage : ::PlaceOS::Model::Storage,
      uploaded_by : String,
      uploaded_email : String,
      file_name : String,
      object_key : String,
      public : Bool = false,
      tags : Array(String) = [] of String,
    ) : ::PlaceOS::Model::Upload
      md5 = Digest::MD5.base64digest(bytes)
      visibility = public ? "public" : "private"

      upload = ::PlaceOS::Model::Upload.new(
        uploaded_by: uploaded_by,
        uploaded_email: ::PlaceOS::Model::Email.new(uploaded_email),
        file_name: file_name,
        file_size: bytes.size.to_i64,
        file_md5: md5,
        storage_id: storage.id,
        object_key: object_key,
        public: public,
        permissions: ::PlaceOS::Model::Upload::Permissions::None,
        object_options: {
          "permissions" => JSON::Any.new(visibility),
          "headers"     => JSON::Any.new({"Content-Type" => JSON::Any.new(mime)}),
        },
        tags: tags,
      )
      raise Error::BadGateway.new("could not record the upload") unless upload.save

      signature = signer_for(storage).sign_upload(
        storage.bucket_name,
        object_key,
        bytes.size.to_i64,
        md5,
        mime,
        public ? :public : :private,
        5.minutes.total_seconds.to_i,
        {"Content-Type" => mime},
      )

      uri = URI.parse(signature[:url])
      headers = HTTP::Headers.new
      # the signature covers these exactly as given, so they go on the wire
      # unchanged
      signature[:headers].each { |key, value| headers[key] = value }

      response = begin
        ImageGen::Http.client(uri, 120.seconds) do |client|
          client.exec(signature[:verb].upcase, uri.request_target, headers: headers, body: bytes)
        end
      rescue error : IO::Error | Socket::Error
        rollback(upload)
        raise Error::BadGateway.new("storage unreachable: #{error.message}")
      end

      unless response.success?
        rollback(upload)
        raise Error::BadGateway.new("storage rejected the file (#{response.status_code})")
      end

      upload.update!(upload_complete: true)
      upload
    end

    # `delete`, not `destroy`: the object never landed, so there's nothing for
    # the `before_destroy` storage cleanup to remove, and that call failing
    # (same broken storage) would leave the row behind
    private def self.rollback(upload : ::PlaceOS::Model::Upload) : Nil
      upload.delete rescue nil
    end
  end
end
