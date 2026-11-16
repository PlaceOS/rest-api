require "placeos-models/authority"
require "placeos-models/storage"
require "placeos-models/upload"

module PlaceOS::Api
  # Domain resources use their selected organisation without changing login identity.
  module Utils::ResourceAuthority
    UPLOAD_AUTHORITY_KEY = "authority_id"

    @resource_authority : ::PlaceOS::Model::Authority? = nil
    @resource_authority_resolved = false

    def resource_authority : ::PlaceOS::Model::Authority?
      return current_authority unless Utils::Tenancy.enforce?
      return @resource_authority if @resource_authority_resolved

      organisation_id = selected_organisation_id
      return unless organisation_id
      requested = query_params.fetch_all("authority_id")
      if requested.size > 1 || requested.first?.try(&.empty?)
        raise Error::OrganisationSelection.new("provide one authority_id", "authority_invalid")
      end

      authority = if id = requested.first?
                    ensure_authority_reach!(id, "authority")
                    ::PlaceOS::Model::Authority.find?(id)
                  elsif (home = current_authority) && home.organisation_id == organisation_id
                    ensure_authority_reach!(home.id, "authority")
                    home
                  else
                    ids = reachable_authority_ids || [] of String
                    if ids.size > 1
                      raise Error::OrganisationSelection.new("select an authority within the organisation", "authority_required")
                    end
                    ids.first?.try { |candidate| ::PlaceOS::Model::Authority.find?(candidate) }
                  end
      @resource_authority = authority
      @resource_authority_resolved = true
      authority
    end

    def resource_authority! : ::PlaceOS::Model::Authority
      resource_authority || raise Error::NotFound.new("authority not found")
    end

    # A row identifies its domain without an arbitrary choice among sibling domains.
    def authority_for_resource!(authority_id : String?, resource : String = "resource", required : ::PlaceOS::Model::Permissions = tenancy_permission) : ::PlaceOS::Model::Authority
      return resource_authority! unless Utils::Tenancy.enforce?
      ensure_resource_authority!(authority_id, resource, required: required)
      if requested = query_params["authority_id"]?
        raise Error::NotFound.new("#{resource} not found") unless requested == authority_id
      end
      authority = authority_id.try { |id| ::PlaceOS::Model::Authority.find?(id) }
      raise Error::NotFound.new("#{resource} not found") unless authority
      @resource_authority = authority
      @resource_authority_resolved = true
      authority
    end

    def ensure_resource_authority!(authority_id : String?, resource : String = "resource", shared : Bool = false, required : ::PlaceOS::Model::Permissions = tenancy_permission) : Nil
      return unless Utils::Tenancy.enforce?
      if authority_id.nil? && shared
        check_cluster_admin unless required == ::PlaceOS::Model::Permissions::Read
        return
      end
      ensure_authority_reach!(authority_id, resource, required: required)
    end

    # New shared-storage uploads record their target; legacy uploads inherit storage or uploader ownership.
    def upload_authority_id(upload : ::PlaceOS::Model::Upload) : String?
      upload.object_options[UPLOAD_AUTHORITY_KEY]?.try(&.as_s?) || upload.storage.try(&.authority_id) || upload.user.try(&.authority_id)
    end

    def ensure_upload_reach!(upload : ::PlaceOS::Model::Upload, required : ::PlaceOS::Model::Permissions = tenancy_permission) : Nil
      return unless Utils::Tenancy.enforce?
      storage = upload.storage
      raise Error::NotFound.new("upload not found") unless storage
      ensure_authority_reach!(storage.authority_id, "upload", required: required) if storage.authority_id
      owner = upload_authority_id(upload)
      ensure_authority_reach!(owner, "upload", required: required)
    end
  end
end
