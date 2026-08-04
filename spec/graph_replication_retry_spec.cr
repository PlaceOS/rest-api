require "./helper"

module PlaceOS::Api
  describe GraphReplicationRetry do
    replication_lag_error = -> do
      Office365::Exception.new(
        HTTP::Status::NOT_FOUND,
        {error: {code: "Request_ResourceNotFound", message: "Resource 'x' does not exist or one of its queried reference-property objects are not present."}}.to_json,
        "Not Found"
      )
    end

    app_not_backed_error = -> do
      Office365::Exception.new(
        HTTP::Status::BAD_REQUEST,
        {error: {code: "Request_BadRequest", message: "The appId 'x' of the service principal does not reference a valid application object.", details: [{code: "NoBackingApplicationObject", message: "The appId 'x' of the service principal does not reference a valid application object.", target: "appId"}]}}.to_json,
        "Bad Request"
      )
    end

    it "returns the block value when the call succeeds" do
      GraphReplicationRetry.run { 42 }.should eq 42
    end

    it "retries service principal creation racing the application object" do
      attempts = 0
      value = GraphReplicationRetry.run(backoff: {0, 0, 0}) do
        attempts += 1
        raise app_not_backed_error.call if attempts < 3
        :materialised
      end
      value.should eq :materialised
      attempts.should eq 3
    end

    it "retries replication lag until the object materialises" do
      attempts = 0
      value = GraphReplicationRetry.run(backoff: {0, 0, 0}) do
        attempts += 1
        raise replication_lag_error.call if attempts < 3
        :materialised
      end
      value.should eq :materialised
      attempts.should eq 3
    end

    it "gives up once the backoff schedule is exhausted" do
      attempts = 0
      expect_raises(Office365::Exception, /Request_ResourceNotFound/) do
        GraphReplicationRetry.run(backoff: {0, 0}) do
          attempts += 1
          raise replication_lag_error.call
        end
      end
      attempts.should eq 3
    end

    it "does not retry other graph errors" do
      attempts = 0
      expect_raises(Office365::Exception) do
        GraphReplicationRetry.run(backoff: {0, 0}) do
          attempts += 1
          raise Office365::Exception.new(HTTP::Status::FORBIDDEN, {error: {code: "Authorization_RequestDenied", message: "denied"}}.to_json, "Forbidden")
        end
      end
      attempts.should eq 1
    end

    it "does not retry 404s that are not replication lag" do
      attempts = 0
      expect_raises(Office365::Exception) do
        GraphReplicationRetry.run(backoff: {0, 0}) do
          attempts += 1
          raise Office365::Exception.new(HTTP::Status::NOT_FOUND, "gone", "Not Found")
        end
      end
      attempts.should eq 1
    end
  end
end
