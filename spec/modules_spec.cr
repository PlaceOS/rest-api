require "./helper"

module Engine::API
  describe Modules do
    with_server do
      test_404(namespace: Modules::NAMESPACE, model_name: Model::Module.table_name)

      describe "CRUD operations" do
        test_crd(klass: Model::Module, controller_klass: Modules)
        pending "update" do
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

          result.success?.should be_true
          updated = Model::Module.from_trusted_json(result.body)
          updated.attributes.should eq mod.attributes
        end
      end

      pending "index" do
        it "looks up by system_id" do
          mod = Model::Generator.module.save!
          id = mod.control_system_id.not_nil!

          params = HTTP::Params.encode({"control_system_id" => id})
          path = "#{Modules::NAMESPACE[0]}?#{params}"

          result = curl(
            method: "GET",
            path: path,
          )

          body = JSON.parse(result.body)
          body["total"].should eq 1
          Engine::Module.from_json(body["results"][0]).should eq mod
        end

        pending "range query"
        pending "connected query"
        pending "no logic query"
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
