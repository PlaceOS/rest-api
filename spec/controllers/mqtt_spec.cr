require "../helper"

module PlaceOS::Api
  describe MQTT do
    with_server do
      authenticated_user, _authorization_header = authentication

      describe "MQTT Access" do
        describe ".mqtt_acl_status" do
          it "denies access for #{MQTT::MqttAcl::None} access" do
            MQTT.mqtt_acl_status(MQTT::MqttAcl::None, authenticated_user).should eq HTTP::Status::FORBIDDEN
          end

          it "denies access for #{MQTT::MqttAcl::Deny} access" do
            MQTT::MqttAcl
              .values
              .reject(MQTT::MqttAcl::Deny)
              .map { |access| access | MQTT::MqttAcl::Deny }
              .each do |access|
                MQTT.mqtt_acl_status(access, authenticated_user).should eq HTTP::Status::FORBIDDEN
              end
          end

          pending "allows #{MQTT::MqttAcl::Read} access"
          pending "allows #{MQTT::MqttAcl::Write} access for support and above"
          pending "denies #{MQTT::MqttAcl::Write} access"
        end
      end
    end
  end
end
