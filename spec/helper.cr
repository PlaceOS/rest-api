require "action-controller/spec_helper"
require "http"
require "mutex"
require "promise"
require "random"
require "rethinkdb-orm"
require "simple_retry"
require "spec"

require "./spec_helpers/*"

include PlaceOS::Api::SpecClient

Spec.before_suite do
  Log.builder.bind("*", backend: PlaceOS::LogBackend::STDOUT, level: :trace)
  clear_tables
end

Spec.before_each do
  PlaceOS::Api::HttpMocks.reset
end

Spec.after_suite { clear_tables }

# Application config
require "../src/config"

# Generators for Engine models
require "placeos-models/spec/generator"

# Configure DB
db_name = "place_#{ENV["SG_ENV"]? || "development"}"

RethinkORM.configure &.db=(db_name)

def clear_tables
  {% begin %}
    Promise.all(
      {% for t in {
                    PlaceOS::Model::Asset,
                    PlaceOS::Model::AssetInstance,
                    PlaceOS::Model::ControlSystem,
                    PlaceOS::Model::Driver,
                    PlaceOS::Model::Module,
                    PlaceOS::Model::Repository,
                    PlaceOS::Model::Settings,
                    PlaceOS::Model::Trigger,
                    PlaceOS::Model::TriggerInstance,
                    PlaceOS::Model::Zone,
                  } %}
        Promise.defer { {{t.id}}.clear },
      {% end %}
    )
  {% end %}
end

CREATION_LOCK = Mutex.new(protection: :reentrant)

# Yield an authenticated user, and a header with X-API-Key set
def x_api_authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC])
  CREATION_LOCK.synchronize do
    user, _header = authentication(sys_admin, support, scope)
    unless api_key = user.api_tokens.first?
      api_key = PlaceOS::Model::ApiKey.new
      api_key.user = user
      api_key.name = user.name
      api_key.save!
    end

    authorization_header = HTTP::Headers{
      "X-API-Key"    => api_key.x_api_key.not_nil!,
      "Content-Type" => "application/json",
    }

    {api_key.user, authorization_header}
  end
end

# Yield an authenticated user, and a header with Authorization bearer set
# This method is synchronised due to the redundant top-level calls.
def authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC])
  CREATION_LOCK.synchronize do
    test_user_email = PlaceOS::Model::Email.new("test-admin-#{sys_admin ? "1" : "0"}-supp-#{support ? "1" : "0"}-rest-api@place.tech")
    existing = PlaceOS::Model::User.where(email: test_user_email).first?

    authenticated_user = if existing
                           existing
                         else
                           user = PlaceOS::Model::Generator.user
                           user.sys_admin = sys_admin
                           user.support = support
                           user.save!
                         end

    authorization_header = HTTP::Headers{
      "Authorization" => "Bearer #{PlaceOS::Model::Generator.jwt(authenticated_user, scope).encode}",
      "Content-Type"  => "application/json",
    }

    {authenticated_user, authorization_header}
  end
end

def generate_auth_user(sys_admin, support, scopes)
  scope_list = scopes.try &.join('-', &.to_s)
  test_user_email = PlaceOS::Model::Email.new("test-#{"admin-" if sys_admin}#{"supp" if support}-scope-#{scope_list}-rest-api@place.tech")
  existing = PlaceOS::Model::User.where(email: test_user_email).first?

  existing || PlaceOS::Model::Generator.user.tap do |user|
    user.email = test_user_email
    user.sys_admin = sys_admin
    user.support = support
    user.save!
  end
end

def until_expected(method, path, headers : HTTP::Headers, timeout : Time::Span = 3.seconds, &block : HTTP::Client::Response -> Bool)
  client = ActionController::SpecHelper.client
  channel = Channel(Bool).new
  spawn do
    before = Time.utc
    begin
      SimpleRetry.try_to(base_interval: 50.milliseconds, max_elapsed_time: 2.seconds, retry_on: Exception) do
        result = client.exec(method: method, path: path, headers: headers)

        unless result.success?
          puts "\nrequest failed with: #{result.status_code}"
          puts result.body
        end

        expected = block.call(result)

        raise Exception.new("retry") unless expected || channel.closed?
        channel.send(true) if expected
      end
    rescue e
      raise e unless e.message == "retry"
    ensure
      after = Time.utc
      puts "took #{(after - before).milliseconds}ms"
    end
  end

  spawn do
    sleep timeout
    channel.close
  rescue
  end

  success = channel.receive?
  channel.close
  !!success
end

def random_name
  UUID.random.to_s.split('-').first
end

def refresh_elastic(index : String? = nil)
  path = "/_refresh"
  path = "/#{index}" + path unless index.nil?
  Neuroplastic::Client.new.perform_request("POST", path)
end
