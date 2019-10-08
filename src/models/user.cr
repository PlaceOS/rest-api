require "CrystalEmail"
require "digest/md5"
require "rethinkdb-orm"

# require "scrypt"

require "./authority"
require "./base/model"

module ACAEngine::Model
  class User < ModelBase
    include RethinkORM::Timestamps
    table :user

    belongs_to Authority

    attribute name : String, es_type: "keyword"
    attribute nickname : String
    attribute email : String
    attribute phone : String
    attribute country : String
    attribute image : String
    attribute metadata : String

    attribute login_name : String
    attribute staff_id : String
    attribute first_name : String
    attribute last_name : String
    attribute building : String

    attribute password_digest : String
    # attribute password_digest : Scrypt::Password, converter: Scrypt::Converter

    attribute email_digest : String
    attribute card_number : String

    attribute deleted : Bool = false

    validates :email, presence: true
    validates :authority_id, presence: true

    # Validate email format
    validate ->(this : User) {
      return unless (email = this.email)
      this.validation_error(:email, "is an invalid email") unless email.is_email?
    }

    before_save :create_email_digest

    # Sets email_digest to allow user look up without leaking emails
    #
    protected def create_email_digest
      self.email_digest = Digest::MD5.hexdigest(self.email.as(String))
    end

    def self.find_by_email(authority_id, email)
      User.where(email: email, authority_id: authority_id).first?
    end

    # Ensure email is unique, prepends authority id for searching
    #
    ensure_unique :email, scope: [:authority_id, :email] do |authority_id, email|
      {authority_id, email.strip.downcase}
    end

    ensure_unique :login_name
    ensure_unique :staff_id

    # Publically visible fields
    PUBLIC_DATA = {
      :id, :email_digest, :nickname, :name, :first_name, :last_name,
      :country, :building, {field: :created_at, serialise: :to_unix},
    }

    # Admin visible fields
    ADMIN_DATA = {
      # Public Visible
      :id, :email_digest, :nickname, :name, :first_name, :last_name,
      :country, :building, {field: :created_at, serialise: :to_unix},
      # Admin Visible
      :sys_admin, :support, :email, :phone,
    }

    subset_json(:as_public_json, PUBLIC_DATA)
    subset_json(:as_admin_json, ADMIN_DATA)

    def self.find_by_login_name(login_name)
      User.get_all([login_name], index: :login_name).first?
    end

    def self.find_by_staff_id(staff_id)
      User.get_all([staff_id], index: :staff_id).first?
    end

    attribute sys_admin : Bool = false

    attribute support : Bool = false

    def is_admin?
      !!(@sys_admin)
    end

    def is_support?
      !!(@support)
    end

    before_save :build_name

    def build_name
      if self.first_name
        self.name = "#{self.first_name} #{self.last_name}"
      end
    end

    # ----------------
    # Indices
    # ----------------

    secondary_index :authority_id

    def by_authority_id(auth_id)
      User.get_all([auth_id], index: :authority_id)
    end

    secondary_index :sys_admin

    def self.find_sys_admins
      User.get_all([true], index: :sys_admin)
    end

    # # PASSWORD ENCRYPTION::
    # # ---------------------
    #
    # def authenticate(unencrypted_password)
    #   # accounts created with social logins will have an empty password_digest
    #   return nil if unencrypted_password.size == 0
    #
    #   if @password_digest.try &.verify(unencrypted_password)
    #     self
    #   else
    #     nil
    #   end
    # end
    #
    # attribute password : String, persistence: false, allow_blank: true, confirmation: true, mass_assignment: false do |password|
    #   (password || "").tap do |p|
    #     unless p.empty?
    #       self.password_digest = Scrypt::Password.create(
    #         password: p,
    #         key_len: 32,
    #         salt_size: 32,
    #         max_mem: 16 * 1024 * 1024,
    #         max_memfrac: 0.5,
    #         max_time: 0.2,
    #       )
    #     end
    #   end
    # end
    #
    # validates :password, length: {minimum: 6, wrong_length: "must be at least 6 characters"}
    #
    # # --------------------
    # # END PASSWORD METHODS
  end
end
