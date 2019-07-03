require "uri"

require "./base/model"

module Engine::Model
  class Authority < ModelBase
    table :authority

    attribute name : String, es_type: "keyword"

    attribute domain : String
    ensure_unique :domain, create_index: true

    attribute description : String

    attribute login_url : String = "/auth/login?continue={{url}}"
    attribute logout_url : String = "/auth/logout"

    attribute internals : String
    attribute config : String

    validates :name, presence: true

    # Ensure we are only saving the host
    #
    def domain=(dom)
      parsed = URI.parse(dom)
      previous_def(parsed.host.try &.downcase)
    end

    # Locates an Authority by its unique domain name
    #
    def self.find_by_domain(domain)
      Authority.find_all([domain], index: :domain).first?
    end
  end
end
