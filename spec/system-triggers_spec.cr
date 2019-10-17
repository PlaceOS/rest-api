require "./helper"

module ACAEngine::Api
  describe SystemTriggers do
    _, authorization_header = authentication
    base = SystemTriggers::NAMESPACE[0]

    with_server do
      test_404(
        base.gsub(/:sys_id/, "sys-#{Random.rand(9999)}"),
        model_name: Model::TriggerInstance.table_name,
        headers: authorization_header,
      )
      describe "index" do
        it "as_of query" do
          inst1 = Model::Generator.trigger_instance.save!
          inst1.persisted?.should be_true

          sleep 1

          inst2 = Model::Generator.trigger_instance.save!
          inst2.persisted?.should be_true

          params = HTTP::Params.encode({"as_of" => (inst1.updated_at.try &.to_unix).to_s})
          path = "#{base}?#{params}"

          sleep 1

          result = curl(
            method: "GET",
            path: path,
            headers: authorization_header,
          )
          results = JSON.parse(result.body)["results"].as_a

          contains_correct = results.any? { |r| r["id"] == inst1.id }
          contains_incorrect = results.any? { |r| r["id"] == inst2.id }

          contains_correct.should be_true
          contains_incorrect.should be_false
        end
      end

      describe "CRUD operations" do
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
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
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
          result = curl(method: "GET", path: path, headers: authorization_header)

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
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::TriggerInstance.from_json(result.body)

          updated.id.should eq trigger_instance.id
          updated.important.should_not eq original_importance
        end

        it "destroy" do
          sys = ACAEngine::Model::Generator.control_system.save!
          model = ACAEngine::Model::Generator.trigger_instance
          model.control_system = sys

          model.save!
          model.persisted?.should be_true

          id = model.id.not_nil!
          path = base.gsub(/:sys_id/, sys.id) + id

          result = curl(method: "DELETE", path: path, headers: authorization_header)
          result.status_code.should eq 200

          Model::TriggerInstance.find(id).should be_nil
        end
      end
    end
  end
end
