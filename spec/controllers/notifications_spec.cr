require "../helper"

module PlaceOS::Api
  describe PushNotifications do
    describe "google push notification" do
      it "should return 202 accepted to google sync notification" do
        result = client.post("#{PushNotifications.base_route}/google", headers: HTTP::Headers{
          "Host"                      => "localhost",
          "Content-Type"              => "application/json",
          "Content-Length"            => "0",
          "X-Goog-Channel-ID"         => "4ba78bf0-6a47-11e2-bcfd-0800200c9a66",
          "X-Goog-Channel-Token"      => "398348u3tu83ut8uu38",
          "X-Goog-Channel-Expiration" => "Fri, 26 May 2023 01:13:52 GMT",
          "X-Goog-Resource-ID"        => "ret08u3rv24htgh289g",
          "X-Goog-Resource-URI"       => "https://www.googleapis.com/calendar/v3/calendars/my_calendar@gmail.com/events",
          "X-Goog-Resource-State"     => "sync",
          "X-Goog-Message-Number"     => "1",
        }
        )
        result.status_code.should eq 202
      end

      it "should receive valid payload when google sends change notification" do
        authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
        subscription_channel = "#{authority.id}/calendar/event"

        channel = Channel(String).new
        subs = PlaceOS::Driver::Subscriptions.new

        _subscription = subs.channel subscription_channel do |_, message|
          channel.send(message)
        end

        result = client.post("#{PushNotifications.base_route}/google", headers: HTTP::Headers{
          "Host"                      => "localhost",
          "Content-Type"              => "application/json",
          "Content-Length"            => "0",
          "X-Goog-Channel-ID"         => "4ba78bf0-6a47-11e2-bcfd-0800200c9a66",
          "X-Goog-Channel-Token"      => "398348u3tu83ut8uu38",
          "X-Goog-Channel-Expiration" => "Fri, 26 May 2023 01:13:52 GMT",
          "X-Goog-Resource-ID"        => "ret08u3rv24htgh289g",
          "X-Goog-Resource-URI"       => "https://www.googleapis.com/calendar/v3/calendars/my_calendar@gmail.com/events",
          "X-Goog-Resource-State"     => "exists",
          "X-Goog-Message-Number"     => "1",
        }
        )
        result.status_code.should eq 202

        begin
          select
          when message = channel.receive
            [{
              "event_type":      "updated",
              "resource_id":     "ret08u3rv24htgh289g",
              "resource_uri":    "https://www.googleapis.com/calendar/v3/calendars/my_calendar@gmail.com/events",
              "subscription_id": "4ba78bf0-6a47-11e2-bcfd-0800200c9a66",
              "client_secret":   "398348u3tu83ut8uu38",
              "expiration_time": 1685063632,
            }].to_json.should eq(message)
          when timeout 2.seconds
            raise "timeout"
          end
        ensure
          subs.terminate
        end
      end
    end

    describe "microsoft push notifications" do
      it "should return 200 and token back to validation check" do
        token = "SomeToken"
        result = client.post("#{PushNotifications.base_route}/office365?validationToken=#{token}", headers: HTTP::Headers{
          "Host"         => "localhost",
          "Content-Type" => "text/plain",
        })

        result.status_code.should eq 200
        result.headers["Content-Type"].should eq("text/plain")
        result.body.should eq(token)
      end

      it "should receive valid payload when microsoft sends change notification" do
        authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
        subscription_channel = "#{authority.id}/calendar/event"

        channel = Channel(String).new
        subs = PlaceOS::Driver::Subscriptions.new

        _subscription = subs.channel subscription_channel do |_, message|
          channel.send(message)
        end

        payload = <<-'JSON'
        {
            "value": [
                {
                    "subscriptionId": "f37536ac-b308-4bc7-b239-b2b51cd2ff24",
                    "subscriptionExpirationDateTime": "2023-05-26T23:29:18.2277768+00:00",
                    "changeType": "created",
                    "resource": "Users/2189c720-90d5-44ff-818b-fe585706ee90/Events/AAMkADlhNjJjN2M1LTJiYWUtNGVhMS04ODEzLTRjNDlmYmZkYWMyYQBGAAAAAAA2241OoLZoSZGqNr4MvSZJBwAXxlVK8zI-TZLFIn9D86hXAAAAAAENAAAXxlVK8zI-TZLFIn9D86hXAAAECHE1AAA=",
                    "resourceData": {
                        "@odata.type": "#Microsoft.Graph.Event",
                        "@odata.id": "Users/2189c720-90d5-44ff-818b-fe585706ee90/Events/AAMkADlhNjJjN2M1LTJiYWUtNGVhMS04ODEzLTRjNDlmYmZkYWMyYQBGAAAAAAA2241OoLZoSZGqNr4MvSZJBwAXxlVK8zI-TZLFIn9D86hXAAAAAAENAAAXxlVK8zI-TZLFIn9D86hXAAAECHE1AAA=",
                        "@odata.etag": "W/\"DwAAABYAAAAXxlVK8zI/TZLFIn9D86hXAAAEB/jr\"",
                        "id": "AAMkADlhNjJjN2M1LTJiYWUtNGVhMS04ODEzLTRjNDlmYmZkYWMyYQBGAAAAAAA2241OoLZoSZGqNr4MvSZJBwAXxlVK8zI-TZLFIn9D86hXAAAAAAENAAAXxlVK8zI-TZLFIn9D86hXAAAECHE1AAA="
                    },
                    "clientState": "secretClientState",
                    "tenantId": "7f1d0cb7-93b9-405a-8dad-c21703b7af18"
                }
            ]
        }
        JSON
        result = client.post("#{PushNotifications.base_route}/office365", body: payload, headers: HTTP::Headers{
          "Host"         => "localhost",
          "Content-Type" => "application/json",
        })

        result.status_code.should eq 202

        begin
          select
          when message = channel.receive
            [{
              "event_type":      "created",
              "resource_id":     "AAMkADlhNjJjN2M1LTJiYWUtNGVhMS04ODEzLTRjNDlmYmZkYWMyYQBGAAAAAAA2241OoLZoSZGqNr4MvSZJBwAXxlVK8zI-TZLFIn9D86hXAAAAAAENAAAXxlVK8zI-TZLFIn9D86hXAAAECHE1AAA=",
              "resource_uri":    "Users/2189c720-90d5-44ff-818b-fe585706ee90/Events/AAMkADlhNjJjN2M1LTJiYWUtNGVhMS04ODEzLTRjNDlmYmZkYWMyYQBGAAAAAAA2241OoLZoSZGqNr4MvSZJBwAXxlVK8zI-TZLFIn9D86hXAAAAAAENAAAXxlVK8zI-TZLFIn9D86hXAAAECHE1AAA=",
              "subscription_id": "f37536ac-b308-4bc7-b239-b2b51cd2ff24",
              "client_secret":   "secretClientState",
              "expiration_time": 1685143758,
            }].to_json.should eq(message)
          when timeout 2.seconds
            raise "timeout"
          end
        ensure
          subs.terminate
        end
      end

      it "should receive valid payload when microsoft sends lifecycle notification" do
        authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
        subscription_channel = "#{authority.id}/calendar/event"

        channel = Channel(String).new
        subs = PlaceOS::Driver::Subscriptions.new

        _subscription = subs.channel subscription_channel do |_, message|
          channel.send(message)
        end

        payload = <<-'JSON'
        {
            "value": [
                {
                    "subscriptionId": "f37536ac-b308-4bc7-b239-b2b51cd2ff24",
                    "subscriptionExpirationDateTime": "2023-05-26T23:29:18.2277768+00:00",
                    "tenantId": "7f1d0cb7-93b9-405a-8dad-c21703b7af18",  
                    "clientState": "secretClientState",
                    "lifecycleEvent": "reauthorizationRequired"
                }
            ]
        }
        JSON
        result = client.post("#{PushNotifications.base_route}/office365", body: payload, headers: HTTP::Headers{
          "Host"         => "localhost",
          "Content-Type" => "application/json",
        })

        result.status_code.should eq 202

        begin
          select
          when message = channel.receive
            [{
              "event_type":      "reauthorize",
              "resource_id":     nil,
              "resource_uri":    nil,
              "subscription_id": "f37536ac-b308-4bc7-b239-b2b51cd2ff24",
              "client_secret":   "secretClientState",
              "expiration_time": 1685143758,
            }].to_json.should eq(message)
          when timeout 2.seconds
            raise "timeout"
          end
        ensure
          subs.terminate
        end
      end
    end
  end
end
