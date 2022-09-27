require "promise"

require "./application"

module PlaceOS::Api
  class Metadata < Application
    base "/api/engine/v2/metadata"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:history]
    before_action :can_read_guest, only: [:show, :children_metadata]
    before_action :can_write, only: [:update, :destroy, :update_alt]

    # Callbacks
    ###############################################################################################

    # Does the user making the request have permissions to modify the data
    @[AC::Route::Filter(:before_action, only: [:destroy])]
    def check_delete_permissions(
      @[AC::Param::Info(name: "id", description: "the parent id of the metadata to be destroyed")]
      parent_id : String
    )
      # NOTE: Will the user token ever be assigned a zone id?
      raise Error::Forbidden.new unless is_support? || parent_id == user_token.id
    end

    ###############################################################################################

    # Fetch metadata for a model
    #
    # Filter for a specific metadata by name via `name` param
    @[AC::Route::GET("/:id")]
    def show(
      @[AC::Param::Info(name: "id", description: "the parent id of the metadata to be returned")]
      parent_id : String,
      @[AC::Param::Info(description: "the name of the metadata key", example: "config")]
      name : String? = nil
    ) : Hash(String, Model::Metadata::Interface)
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        raise Error::Forbidden.new unless name && guest_ids.includes?(parent_id)
      end

      Model::Metadata.build_metadata(parent_id, name)
    end

    record Children, zone : Model::Zone, metadata : Hash(String, Model::Metadata::Interface) do
      include JSON::Serializable

      def initialize(@zone, metadata_key : String?)
        @metadata = Model::Metadata.build_metadata(@zone, metadata_key)
      end
    end

    # Fetch metadata for Zone children
    #
    # Filter for a specific metadata by name via `name` param.
    # Includes the parent metadata by default via `include_parent` param.
    @[AC::Route::GET("/:id/children")]
    def children_metadata(
      @[AC::Param::Info(name: "id", description: "the parent id of the metadata to be returned")]
      parent_id : String,
      @[AC::Param::Info(description: "the parent metadata is included in the results by default", example: "false")]
      include_parent : Bool = true
    ) : Array(Children)
      # Guest JWTs include the control system id that they have access to
      if user_token.guest_scope?
        raise Error::Forbidden.new unless name && guest_ids.includes?(parent_id)
      end

      Log.context.set(zone_id: parent_id)
      current_zone = Model::Zone.find!(parent_id)
      current_zone.children.all.compact_map do |zone|
        Children.new(zone, name).to_json(json) if include_parent || zone.id != parent_id
      end
    end

    @[AC::Route::PATCH("/:id", body: :meta)]
    def merge(
      @[AC::Param::Info(name: "id", description: "the parent id of the metadata to be updated")]
      parent_id : String,
      meta : Model::Metadata::Interface
    ) : Model::Metadata::Interface
      mutate(parent_id, meta, merge: true)
    end

    @[AC::Route::PUT("/:id", body: :meta)]
    def update(
      @[AC::Param::Info(name: "id", description: "the parent id of the metadata to be replaced")]
      parent_id : String,
      meta : Model::Metadata::Interface
    ) : Model::Metadata::Interface
      mutate(parent_id, meta, merge: false)
    end

    SIGNAL_CHANNEL = "placeos/metadata/changed"

    protected def self.signal_metadata(action : Symbol, metadata) : Nil
      payload = {
        action:   action,
        metadata: metadata,
      }.to_json

      Log.info { "signalling #{SIGNAL_CHANNEL} with #{payload.bytesize} bytes" }

      ::PlaceOS::Driver::RedisStorage.with_redis &.publish(SIGNAL_CHANNEL, payload)
    end

    # Find (otherwise create) then update (or patch) the Metadata.
    protected def mutate(parent_id : String, metadata : Model::Metadata::Interface, merge : Bool)
      # A name is required to lookup the metadata
      raise Error::ModelValidation.new({Error::Field.new(:name, "Name must not be empty")}) unless metadata.name.presence

      metadata = create_or_update(parent_id, metadata, merge: merge)
      raise Error::ModelValidation.new(metadata.errors) unless metadata.save
      metadata

      payload = metadata.interface
      spawn { self.class.signal_metadata(:update, payload) }
      payload
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy(
      @[AC::Param::Info(name: "id", description: "the parent id of the metadata to be returned")]
      parent_id : String,
      @[AC::Param::Info(name: "name", description: "the name of the metadata key", example: "config")]
      metadata_name : String
    ) : Nil
      Model::Metadata.for(parent_id, metadata_name).each &.destroy

      spawn do
        if metadata_name.empty?
          self.class.signal_metadata(:destroy_all, {
            parent_id: parent_id,
          })
        else
          self.class.signal_metadata(:destroy, {
            parent_id: parent_id,
            name:      metadata_name,
          })
        end
      end
    end

    # Returns the version history for a Settings model
    @[AC::Route::GET("/:id/children")]
    def history(
      @[AC::Param::Info(name: "id", description: "the parent id of the metadata to be returned")]
      parent_id : String,
      @[AC::Param::Info(description: "the name of the metadata key", example: "config")]
      name : String? = nil,
      @[AC::Param::Info(description: "the maximum number of results to return", example: "10000")]
      limit : Int32 = 100,
      @[AC::Param::Info(description: "the starting offset of the result set. Used to implement pagination")]
      offset : Int32 = 0
    ) : Hash(String, Array(Model::Metadata::Interface))
      history = Model::Metadata.build_history(parent_id, name, offset: offset, limit: limit)

      total = Model::Metadata.for(parent_id, name).max_of?(&.history_count) || 0
      range_start = offset
      range_end = (history.max_of?(&.last.size) || 0) + range_start

      response.headers["X-Total-Count"] = total.to_s
      response.headers["Content-Range"] = "metadata #{range_start}-#{range_end}/#{total}"

      # Set link
      if range_end < total
        params["offset"] = (range_end + 1).to_s
        params["limit"] = limit.to_s
        path = File.join(base_route, "/#{parent_id}/history")
        response.headers["Link"] = %(<#{path}?#{query_params}>; rel="next")
      end

      history
    end

    # Helpers
    ###########################################################################

    def create_or_update(parent_id : String, interface : Model::Metadata::Interface, merge : Bool) : Model::Metadata
      if metadata = Model::Metadata.for(parent_id, interface.name).first?
        # Check if the current user has access
        raise Error::Forbidden.new unless metadata.user_can_update?(user_token)

        metadata.assign_from_interface(user_token, interface, merge)
      else
        # When creating a new metadata, must be at least a support user or own the metadata
        raise Error::Forbidden.new unless Model::Metadata.user_can_create?(parent_id, user_token)

        # Create a new Metadata
        Model::Metadata.from_interface(interface).tap do |model|
          # Set `parent_id` in create
          model.parent_id = parent_id
        end
      end.tap do |model|
        model.modified_by = current_user
      end
    end

    # Fetch zones for system the current user has a role for
    def guest_ids
      sys_id = user_token.user.roles.last
      Model::ControlSystem.find!(sys_id, runopts: {"read_mode" => "majority"}).zones + [sys_id]
    end
  end
end
