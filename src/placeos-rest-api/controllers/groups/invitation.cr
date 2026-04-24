require "uuid"
require "uuid/json"

require "placeos-models/group"
require "placeos-models/group/invitation"

require "../application"

module PlaceOS::Api
  class Groups::Invitations < Application
    include Utils::GroupPermissions

    base "/api/engine/v2/group_invitations/"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :destroy, :accept]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def find_current_invitation(id : String)
      Log.context.set(invitation_id: id)
      @current_invitation = ::PlaceOS::Model::GroupInvitation.find!(UUID.new(id))
    end

    getter! current_invitation : ::PlaceOS::Model::GroupInvitation

    # Permission gates
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:show, :destroy])]
    def check_modify_permissions
      return if user_admin?
      group = ::PlaceOS::Model::Group.find!(current_invitation.group_id)
      ensure_manage!(current_user, group)
    end
    # create's permission check is done inline in the action, since the
    # incoming body is typed as `InvitationCreatePayload` (not the model)
    # and can't easily be consumed in a before_action without colliding
    # with the action's body binding.

    ###############################################################################################

    # Create payload — the plaintext secret is generated server-side and
    # returned *once* in the response's `plaintext_secret` field. It is
    # not persisted; callers must capture it immediately.
    struct InvitationCreatePayload
      include JSON::Serializable

      getter group_id : String
      getter email : String
      getter permissions : Int32 = 0
      getter expires_at : Time? = nil
    end

    # Response struct that exposes the plaintext secret on creation.
    struct InvitationCreatedResponse
      include JSON::Serializable

      getter invitation : ::PlaceOS::Model::GroupInvitation
      getter plaintext_secret : String

      def initialize(@invitation, @plaintext_secret)
      end
    end

    # List invitations. Optionally filter by `group_id`. Non-admin
    # callers must have Manage on the target group.
    @[AC::Route::GET("/")]
    def index(
      group_id : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array(::PlaceOS::Model::GroupInvitation)
      authority_id = current_authority.as(::PlaceOS::Model::Authority).id.as(String)
      authority_group_ids = ::PlaceOS::Model::Group
        .where(authority_id: authority_id)
        .to_a
        .map { |g| g.id.as(UUID) }
      return [] of ::PlaceOS::Model::GroupInvitation if authority_group_ids.empty?

      query = ::PlaceOS::Model::GroupInvitation.where(group_id: authority_group_ids)

      if group_id
        target = UUID.new(group_id)
        unless user_admin?
          group = ::PlaceOS::Model::Group.find!(target)
          ensure_manage!(current_user, group)
        end
        query = query.where(group_id: target)
      else
        unless user_admin?
          managed = manageable_group_ids(current_user)
          return [] of ::PlaceOS::Model::GroupInvitation if managed.empty?
          query = query.where(group_id: managed)
        end
      end

      paginate_sql(query, type: "group_invitations", limit: limit, offset: offset)
    end

    @[AC::Route::GET("/:id")]
    def show : ::PlaceOS::Model::GroupInvitation
      current_invitation
    end

    # Custom body-driven create so we can return the plaintext secret
    # alongside the invitation. Authorisation check is inline here (not
    # a before_action) so the body is consumed exactly once.
    @[AC::Route::POST("/", body: :payload, status_code: HTTP::Status::CREATED)]
    def create(payload : InvitationCreatePayload) : InvitationCreatedResponse
      group = ::PlaceOS::Model::Group.find!(UUID.new(payload.group_id))
      ensure_manage!(current_user, group) unless user_admin?

      perms = ::PlaceOS::Model::Permissions.new(payload.permissions)
      invitation = ::PlaceOS::Model::GroupInvitation.build_with_secret(
        group: group,
        email: payload.email,
        permissions: perms,
        expires_at: payload.expires_at,
      )
      invitation.acting_user = current_user
      raise Error::ModelValidation.new(invitation.errors) unless invitation.save
      InvitationCreatedResponse.new(invitation, invitation.plaintext_secret.as(String))
    end

    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      invitation = current_invitation
      invitation.acting_user = current_user
      invitation.destroy
    end

    # Accept the invitation, materialising it into a GroupUser for the
    # current user. The invitation row is destroyed on success.
    @[AC::Route::POST("/:id/accept")]
    def accept : ::PlaceOS::Model::GroupUser
      invitation = current_invitation
      raise Error::Forbidden.new("invitation expired") if invitation.expired?
      invitation.accept!(current_user)
    end
  end
end
