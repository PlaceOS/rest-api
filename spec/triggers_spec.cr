require "./helper"

module PlaceOS::Api
  describe Triggers do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Triggers::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::Trigger.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        test_base_index(klass: Model::Trigger, controller_klass: Triggers)
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Trigger, controller_klass: Triggers)
        it "update" do
          trigger = Model::Generator.trigger.save!
          original_name = trigger.name
          trigger.name = Faker::Hacker.noun

          id = trigger.id.as(String)
          path = base + id
          result = curl(
            method: "PATCH",
            path: path,
            body: trigger.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::Trigger.from_trusted_json(result.body)

          updated.id.should eq trigger.id
          updated.name.should_not eq original_name
          updated.destroy
        end
      end
    end
  end
end
