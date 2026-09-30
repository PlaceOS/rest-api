require "upload-signer"
require "placeos-models/storage"
require "placeos-models/upload"

module PlaceOS::Api::ImageGen
  # Writes a generated image into the domain's object storage via `ObjectStore`,
  # from outside a request.
  module Store
    CANDIDATE_TAG = "ai-candidate"
    REFERENCE_TAG = "ai-reference"

    record Stored, upload : ::PlaceOS::Model::Upload, width : Int32?, height : Int32?

    def self.signer_for(storage : ::PlaceOS::Model::Storage) : UploadSigner::Storage
      ObjectStore.signer_for(storage)
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

      upload = ObjectStore.put(
        image.bytes,
        image.mime,
        storage,
        user,
        file_name: "ai-#{job_id}-#{index}.#{extension}",
        object_key: "/#{hostname}/ai/#{job_id}/#{index}.#{extension}",
        # candidates are private until the user keeps one
        public: false,
        tags: [CANDIDATE_TAG, "ai-job-#{job_id}"],
      )

      Stored.new(upload: upload, width: image.width, height: image.height)
    rescue error : Error::BadGateway
      raise Error::ImageGen::Vendor.new(error.message || "storage failed")
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
