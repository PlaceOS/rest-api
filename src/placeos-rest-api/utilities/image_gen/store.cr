require "digest/md5"
require "upload-signer"
require "placeos-models/storage"
require "placeos-models/upload"

module PlaceOS::Api::ImageGen
  # Writes a generated image into the domain's object storage through the same
  # `Storage` and `Upload` machinery the uploads controller uses, from outside a
  # request: signs a PUT, sends the bytes with the signature headers verbatim,
  # then marks the row complete.
  module Store
    CANDIDATE_TAG = "ai-candidate"
    REFERENCE_TAG = "ai-reference"

    record Stored, upload : ::PlaceOS::Model::Upload, width : Int32?, height : Int32?

    def self.signer_for(storage : ::PlaceOS::Model::Storage) : UploadSigner::Storage
      UploadSigner.signer(
        UploadSigner::StorageType.from_value(storage.storage_type.value),
        storage.access_key,
        storage.decrypt_secret,
        storage.region,
        endpoint: storage.endpoint,
      )
    end

    # `hostname` comes from the request that started the job: the fiber has no
    # request, and the object key convention starts with the domain.
    def self.put(
      image : AdapterImage,
      storage : ::PlaceOS::Model::Storage,
      user : ::PlaceOS::Model::User,
      hostname : String,
      job_id : String,
      index : Int32,
    ) : Stored
      extension = case image.mime
                  when "image/png"  then "png"
                  when "image/webp" then "webp"
                  else                   "jpg"
                  end

      file_name = "ai-#{job_id}-#{index}.#{extension}"
      object_key = "/#{hostname}/ai/#{job_id}/#{index}.#{extension}"
      md5 = Digest::MD5.base64digest(image.bytes)

      upload = ::PlaceOS::Model::Upload.new(
        uploaded_by: user.id.as(String),
        uploaded_email: user.email,
        file_name: file_name,
        file_size: image.bytes.size.to_i64,
        file_md5: md5,
        storage_id: storage.id,
        object_key: object_key,
        # candidates are private until the user keeps one
        public: false,
        permissions: ::PlaceOS::Model::Upload::Permissions::None,
        object_options: {
          "permissions" => JSON::Any.new("private"),
          "headers"     => JSON::Any.new({"Content-Type" => JSON::Any.new(image.mime)}),
        },
        tags: [CANDIDATE_TAG, "ai-job-#{job_id}"],
      )
      raise Error::ImageGen::Vendor.new("could not record the generated image") unless upload.save

      signer = signer_for(storage)
      signature = signer.sign_upload(
        storage.bucket_name,
        object_key,
        image.bytes.size.to_i64,
        md5,
        image.mime,
        :private,
        5.minutes.total_seconds.to_i,
        {"Content-Type" => image.mime},
      )

      uri = URI.parse(signature[:url])
      headers = HTTP::Headers.new
      # the signature covers these exactly as given, so they go on the wire
      # unchanged
      signature[:headers].each { |key, value| headers[key] = value }

      response = Http.client(uri, 120.seconds) do |client|
        client.exec(signature[:verb].upcase, uri.request_target, headers: headers, body: image.bytes)
      end

      unless response.success?
        upload.destroy rescue nil
        raise Error::ImageGen::Vendor.new("storage rejected the image (#{response.status_code})")
      end

      upload.update!(upload_complete: true)

      Stored.new(upload: upload, width: image.width, height: image.height)
    end

    # Read an upload back out, for a source image or a reference.
    def self.fetch(upload : ::PlaceOS::Model::Upload) : Reference
      storage = upload.storage
      raise Error::ImageGen::NotConfigured.new("upload #{upload.id} has no storage") if storage.nil?

      url = signer_for(storage).get_object(storage.bucket_name, upload.object_key, 5.minutes.total_seconds.to_i)
      bytes, mime = Http.get_bytes(url)

      # trust the file header over whatever the bucket reported
      Reference.new(bytes: bytes, mime: Http.mime_of(bytes, mime))
    end
  end
end
