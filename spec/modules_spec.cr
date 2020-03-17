require "./helper"

module PlaceOS::Api
  describe Modules do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Modules::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::Module.table_name, headers: authorization_header)

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Module, controller_klass: Modules)

        it "update" do
          mod = Model::Generator.module.save!
          connected = mod.connected.not_nil!
          mod.connected = !connected

          sleep 0.1

          id = mod.id.as(String)
          path = base + id
          result = curl(
            method: "PATCH",
            path: path,
            body: mod.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::Module.from_trusted_json(result.body)
          updated.id.should eq mod.id
          updated.connected.should eq !connected
        end
      end

      describe "index", tags: "search" do
        test_base_index(klass: Model::Module, controller_klass: Modules)

        it "looks up by system_id" do
          mod = Model::Generator.module.save!
          sys = mod.control_system.not_nil!

          sys.modules = [mod.id.as(String)]
          sys.save!

          params = HTTP::Params.encode({"control_system_id" => sys.id.as(String)})
          path = "#{base}?#{params}"

          found = until_expected("GET", path, authorization_header) do |response|
            body = JSON.parse(response.body)
            got_one = response.headers["X-Total-Count"] == "1"
            right_one = body[0]["id"] == mod.id
            got_one && right_one
          end

          found.should be_true
        end

        it "as_of query" do
          mod1 = Model::Generator.module
          mod1.connected = true
          mod1.save!
          mod1.persisted?.should be_true

          sleep 0.5

          mod2 = Model::Generator.module
          mod2.connected = true
          mod2.save!
          mod2.persisted?.should be_true

          sleep 0.5

          params = HTTP::Params.encode({"as_of" => (mod1.updated_at.try &.to_unix).to_s})
          path = "#{base}?#{params}"

          found = until_expected("GET", path, authorization_header) do |response|
            results = JSON.parse(response.body).as_a
            contains_correct = results.any? { |r| r["id"] == mod1.id }
            contains_incorrect = results.any? { |r| r["id"] == mod2.id }
            contains_correct && !contains_incorrect
          end

          found.should be_true
        end

        it "connected query" do
          mod = Model::Generator.module
          mod.connected = true
          mod.save!
          mod.persisted?.should be_true

          params = HTTP::Params.encode({"connected" => "true"})
          path = "#{base}?#{params}"

          found = until_expected("GET", path, authorization_header) do |response|
            results = JSON.parse(response.body).as_a

            all_connected = results.all? { |r| r["connected"] != "true" }
            contains_created = results.any? { |r| r["id"] == mod.id }

            all_connected && contains_created
          end

          found.should be_true
        end

        it "no logic query" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
          mod = Model::Generator.module
          mod.driver = driver
          mod.save!

          params = HTTP::Params.encode({"no_logic" => "true"})
          path = "#{base}?#{params}"

          found = until_expected("GET", path, authorization_header) do |response|
            results = JSON.parse(response.body).as_a

            no_logic = results.all? { |r| r["role"] != Model::Driver::Role::Logic.to_i }
            contains_created = results.any? { |r| r["id"] == mod.id }

            no_logic && contains_created
          end

          found.should be_true
        end
      end

      describe "ping" do
        it "fails for logic module" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Logic)
          mod = Model::Generator.module(driver: driver).save!
          path = "#{base}#{mod.id}/ping"
          result = curl(
            method: "POST",
            path: path,
            headers: authorization_header,
          )

          result.success?.should be_false
          result.status_code.should eq 406
        end

        it "pings a module" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Device)
          driver.default_port = 8080
          driver.save!
          mod = Model::Generator.module(driver: driver)
          mod.ip = "127.0.0.1"
          mod.save!

          path = "#{base}#{mod.id}/ping"
          result = curl(
            method: "POST",
            path: path,
            headers: authorization_header,
          )

          body = JSON.parse(result.body)
          result.success?.should be_true
          body["pingable"].should be_true
        end
      end
    end
  end
end
