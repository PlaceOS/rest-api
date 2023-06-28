require "action-controller/spec_helper"
require "http"
require "mutex"
require "promise"
require "random"
require "pg-orm"
require "simple_retry"
require "spec"

require "./spec_helpers/*"

include PlaceOS::Api::SpecClient

abstract class ActionController::Base
  macro inherited
    macro finished
      {% begin %}
      def self.base_route
        NAMESPACE[0]
      end
      {% end %}
    end
  end
end

module PlaceOS::Api
  include Spec::Authentication
end

Spec.before_suite do
  Log.builder.bind("*", backend: PlaceOS::LogBackend::STDOUT, level: :error)
  clear_tables
  PlaceOS::Api::Spec::Authentication.authenticated
end

Spec.after_suite { clear_tables }

Spec.before_each do
  PlaceOS::Api::HttpMocks.reset
end

# Application config
require "../src/config"

# Generators for Engine models
require "placeos-models/spec/generator"

# Configure DB
PgORM::Database.configure { |_| }

def clear_tables
  {% begin %}
    Promise.all(
      {% for t in {
                    PlaceOS::Model::ApiKey,
                    PlaceOS::Model::AssetCategory,
                    PlaceOS::Model::AssetType,
                    PlaceOS::Model::Asset,
                    PlaceOS::Model::AssetPurchaseOrder,
                    PlaceOS::Model::Authority,
                    PlaceOS::Model::ControlSystem,
                    PlaceOS::Model::Driver,
                    PlaceOS::Model::Module,
                    PlaceOS::Model::Repository,
                    PlaceOS::Model::Settings,
                    PlaceOS::Model::Trigger,
                    PlaceOS::Model::TriggerInstance,
                    PlaceOS::Model::User,
                    PlaceOS::Model::Zone,
                  } %}
        Promise.defer { {{t.id}}.clear },
      {% end %}
    ).get
  {% end %}
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

  select
  when found = channel.receive?
    channel.close
    !!found
  when timeout(timeout)
    false
  end
end

def random_name
  UUID.random.to_s.split('-').first
end

def refresh_elastic(index : String? = nil)
  path = "/_refresh"
  path = "/#{index}" + path unless index.nil?
  Neuroplastic::Client.new.perform_request("POST", path)
end
