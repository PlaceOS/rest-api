require "uri"

require "./base/model"

module ACAEngine::Model
  class Authority < ModelBase
    table :authority

    attribute name : String, es_type: "keyword"

    attribute domain : String
    ensure_unique :domain, create_index: true

    attribute description : String

    # TODO: feature request: autogenerate login url
    attribute login_url : String = "/auth/login?continue={{url}}"
    attribute logout_url : String = "/auth/logout"

    attribute internals : Hash(String, String) = {} of String => String
    attribute config : Hash(String, String) = {} of String => String

    validates :name, presence: true

    # Ensure we are only saving the host
    #
    def domain=(dom)
      parsed = URI.parse(dom)
      previous_def(parsed.host.try &.downcase)
    end

    # locates an authority by its unique domain name
    #
    def self.find_by_domain(domain) : Authority?
      Authority.find_all([domain], index: :domain).first?
    end
  end
end
