require "./helper"

module Engine::API
  describe Triggers do
    with_server do
      test_404(namespace: Triggers::NAMESPACE, model_name: Model::Trigger.table_name)
      pending "index"
      describe "CRUD operations" do
        test_crd(klass: Model::Trigger, controller_klass: Triggers)
        it "update" do
          trigger = Model::Generator.trigger.save!
          original_name = trigger.name
          trigger.name = Faker::Hacker.noun

          id = trigger.id.not_nil!
          path = Triggers::NAMESPACE[0] + id
          result = curl(
            method: "PATCH",
            path: path,
            body: trigger.to_json,
            headers: {"Content-Type" => "application/json"},
          )

          result.status_code.should eq 200
          updated = Model::Trigger.from_json(result.body)

          updated.id.should eq trigger.id
          updated.name.should_not eq original_name
        end
      end
    end
  end
end
