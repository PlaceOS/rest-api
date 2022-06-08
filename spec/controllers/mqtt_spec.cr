require "../helper"

module PlaceOS::Api
  describe MQTT do
    scope = [PlaceOS::Model::UserJWT::Scope.new("mqtt", :write)]
    authenticated_user, _scoped_authorization_header = authentication(scope: scope)
    user_jwt = PlaceOS::Model::Generator.jwt(authenticated_user, scope)

    describe "MQTT Access" do
      describe ".mqtt_acl_status" do
        it "denies access for #{MQTT::MqttAcl::None} access" do
          MQTT.mqtt_acl_status(MQTT::MqttAcl::None, user_jwt).should eq HTTP::Status::FORBIDDEN
        end

        it "denies access for #{MQTT::MqttAcl::Deny} access" do
          MQTT::MqttAcl
            .values
            .reject(MQTT::MqttAcl::Deny)
            .map { |access| access | MQTT::MqttAcl::Deny }
            .each do |access|
              MQTT.mqtt_acl_status(access, user_jwt).should eq HTTP::Status::FORBIDDEN
            end
        end

        it "allows #{MQTT::MqttAcl::Read} access" do
          scope = [PlaceOS::Model::UserJWT::Scope.new("mqtt", :read)]
          authenticated_user, _scoped_authorization_header = authentication(scope: scope)
          user_jwt = PlaceOS::Model::Generator.jwt(authenticated_user, scope)
          MQTT.mqtt_acl_status(MQTT::MqttAcl::Read, user_jwt).should eq HTTP::Status::OK
        end

        it "allows #{MQTT::MqttAcl::Write} access for support and above" do
          scope = [PlaceOS::Model::UserJWT::Scope.new("mqtt", :write)]
          authenticated_user, _scoped_authorization_header = authentication(scope: scope)
          user_jwt = PlaceOS::Model::Generator.jwt(authenticated_user, scope)
          MQTT.mqtt_acl_status(MQTT::MqttAcl::Write, user_jwt).should eq HTTP::Status::OK
        end

        it "denies #{MQTT::MqttAcl::Write} access for under support" do
          authenticated_user, _ = authentication(sys_admin: false, support: false, scope: scope)
          user_jwt = PlaceOS::Model::Generator.jwt(authenticated_user, scope)
          MQTT.mqtt_acl_status(MQTT::MqttAcl::Write, user_jwt).should eq HTTP::Status::FORBIDDEN
        end
      end
    end
  end
end
