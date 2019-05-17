require "./helper"

module Engine::API
  describe SystemTriggers do
    base = SystemTriggers::NAMESPACE[0]

    with_server do
      test_404(namespace: [base.gsub(/:sys_id/, "sys-#{Random.rand(9999)}")], model_name: Model::TriggerInstance.table_name)
      pending "index"

      describe "CRUD operations" do
        # TODO: determine if sys_id in path is source of errors
        # Have to manually test these as ControlSystem id needs to be set

        it "create" do
          sys = Model::Generator.control_system.save!
          trigger_instance = Model::Generator.trigger_instance
          trigger_instance.control_system
          body = trigger_instance.to_json

          path = base.gsub(/:sys_id/, sys.id)
          result = curl(
            method: "POST",
            path: path,
            body: body,
            headers: {"Content-Type" => "application/json"},
          )

          result.status_code.should eq 201
          body = result.body.not_nil!

          Model::TriggerInstance.find(JSON.parse(body)["id"].as_s).try &.destroy
        end

        it "show" do
          sys = Model::Generator.control_system.save!
          trigger_instance = Model::Generator.trigger_instance
          trigger_instance.control_system = sys
          trigger_instance.save!
          id = trigger_instance.id.not_nil!

          path = base.gsub(/:sys_id/, sys.id) + id
          result = curl(method: "GET", path: path)

          result.status_code.should eq 200

          response_model = Model::TriggerInstance.from_json(result.body).not_nil!
          response_model.id.should eq id

          sys.destroy
          trigger_instance.destroy
        end

        it "update" do
          sys = Model::Generator.control_system.save!
          trigger_instance = Model::Generator.trigger_instance
          trigger_instance.control_system = sys
          trigger_instance.save!

          original_importance = trigger_instance.important
          updated_importance = !original_importance

          id = trigger_instance.id.not_nil!
          path = base.gsub(/:sys_id/, sys.id) + id

          result = curl(
            method: "PATCH",
            path: path,
            body: {important: updated_importance}.to_json,
            headers: {"Content-Type" => "application/json"},
          )

          result.status_code.should eq 200
          updated = Model::TriggerInstance.from_json(result.body)

          updated.id.should eq trigger_instance.id
          updated.important.should_not eq original_importance
        end

        it "destroy" do
          sys = Engine::Model::Generator.control_system.save!
          model = Engine::Model::Generator.trigger_instance
          model.control_system = sys

          model.save!
          model.persisted?.should be_true

          id = model.id.not_nil!
          path = base.gsub(/:sys_id/, sys.id) + id

          result = curl(method: "DELETE", path: path)
          result.status_code.should eq 200

          Model::TriggerInstance.find(id).should be_nil
        end
      end
    end
  end
end
