require "./application"
require "./notifications/*"

module PlaceOS::Api
  class PushNotifications < Application
    base "/api/engine/v2/notifications"

    skip_action :authorize!, only: [:google, :microsoft]
    skip_action :set_user_id, only: [:google, :microsoft]

    @[AC::Route::Filter(:before_action, only: [:google, :microsoft])]
    def check_authority
      unless @authority = current_authority
        Log.warn { {message: "authority not found", action: "authorize!", host: request.hostname} }
        raise Error::Unauthorized.new "authority not found"
      end
    end

    @[AC::Route::Filter(:before_action, only: :google)]
    def google_sync
      if (google = request.headers["X-Goog-Resource-State"]?) && google.downcase == "sync"
        Log.info { "Google sync notification received with Message Number #{request.headers["X-Goog-Message-Number"]}" }
        render :accepted
      end
    end

    @[AC::Route::Filter(:before_action, only: :microsoft)]
    def ms_validation
      if validation_token = params["validationToken"]?
        Log.info { "Microsoft validation notification received with token: #{validation_token}" }
        render :ok, text: validation_token
      end
    end

    getter! authority : Model::Authority?

    @[AC::Route::POST("/google")]
    def google
      notification = GoogleNotification.from_json(request.headers.to_json)
      signal(notification)
      head :accepted
    end

    @[AC::Route::POST("/office365", body: :notification)]
    def microsoft(notification : MicrosoftNotification)
      signal(notification)
      head :accepted
    end

    private def signal(notification)
      notification.notifications.each do |entry|
        payload = entry.to_payload
        path = "placeos/#{entry.subscription_id}/event"
        Log.info { "signalling #{path} with #{payload.bytesize} bytes" }

        ::PlaceOS::Driver::RedisStorage.with_redis &.publish(path, payload)
      end
    end
  end
end
