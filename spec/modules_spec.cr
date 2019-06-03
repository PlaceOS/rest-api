require "./helper"

module Engine::API
  describe Modules do
    with_server do
      test_404(namespace: Modules::NAMESPACE, model_name: Model::Module.table_name)

      describe "CRUD operations" do
        test_crd(klass: Model::Module, controller_klass: Modules)

        it "update" do
          mod = Model::Generator.module.save!
          connected = mod.connected.not_nil!
          mod.connected = !connected

          id = mod.id.not_nil!
          path = Modules::NAMESPACE[0] + id
          result = curl(
            method: "PATCH",
            path: path,
            body: mod.to_json,
            headers: {"Content-Type" => "application/json"},
          )

          result.status_code.should eq 200
          updated = Model::Module.from_json(result.body)
          updated.id.should eq mod.id
          updated.connected.should eq !connected
        end
      end

      describe "index" do
        test_base_index(klass: Model::Module, controller_klass: Modules)

        it "looks up by system_id" do
          mod = Model::Generator.module.save!
          sys = mod.control_system.not_nil!

          sys.modules = [mod.id.not_nil!]
          sys.save!

          params = HTTP::Params.encode({"control_system_id" => sys.id.not_nil!})
          path = "#{Modules::NAMESPACE[0]}?#{params}"

          result = curl(
            method: "GET",
            path: path,
          )

          body = JSON.parse(result.body)
          body["total"].should eq 1
          body["results"][0]["id"].should eq mod.id
        end

        pending "range query"

        it "connected query" do
          mod = Model::Generator.module
          mod.connected = true
          mod.save!

          params = HTTP::Params.encode({"connected" => "true"})
          path = "#{Modules::NAMESPACE[0]}?#{params}"

          result = curl(
            method: "GET",
            path: path,
          )

          results = JSON.parse(result.body)["results"].as_a

          all_connected = results.all? { |r| r["connected"] != "true" }
          contains_created = results.any? { |r| r["id"] == mod.id }

          all_connected.should be_true
          contains_created.should be_true
        end

        it "no logic query" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Service)
          mod = Model::Generator.module
          mod.driver = driver
          mod.save!

          params = HTTP::Params.encode({"no_logic" => "true"})
          path = "#{Modules::NAMESPACE[0]}?#{params}"

          result = curl(
            method: "GET",
            path: path,
          )

          results = JSON.parse(result.body)["results"].as_a

          no_logic = results.all? { |r| r["role"] != Model::Driver::Role::Logic.to_i }
          contains_created = results.any? { |r| r["id"] == mod.id }

          no_logic.should be_true
          contains_created.should be_true
        end
      end

      describe "ping" do
        it "fails for logic module" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Logic)
          mod = Model::Generator.module(driver: driver).save!
          path = "#{Modules::NAMESPACE[0]}#{mod.id}/ping"
          result = curl(
            method: "POST",
            path: path,
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

          path = "#{Modules::NAMESPACE[0]}#{mod.id}/ping"
          result = curl(
            method: "POST",
            path: path,
          )

          body = JSON.parse(result.body)
          result.success?.should be_true
          body["pingable"].should be_true
        end
      end
    end
  end
end
