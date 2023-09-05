require "../helper"

module PlaceOS::Api
  describe Storages do
    Spec.test_404(Storages.base_route, model_name: Model::Storage.table_name, headers: Spec::Authentication.headers)

    describe "CRUD operations", tags: "crud" do
      it "create" do
        Model::Storage.clear
        storage = PlaceOS::Model::Generator.storage
        storage.mime_filter = ["image/bmp", "image/jpeg", "image/tiff"]
        storage.ext_filter = [".bmp", ".jpg", ".tiff"]
        body = storage.to_json
        result = client.post(
          Storages.base_route,
          body: body,
          headers: Spec::Authentication.headers
        )

        result.status_code.should eq 201
        response_model = Model::Storage.from_trusted_json(result.body)
        response_model.destroy
      end

      it "update" do
        Model::Storage.clear
        storage = Model::Generator.storage.save!
        original_name = storage.bucket_name

        storage.bucket_name = random_name
        storage.mime_filter = ["image/bmp", "image/jpeg", "image/tiff"]
        storage.ext_filter = [".bmp", ".jpg", ".tiff"]

        id = storage.id.as(String)
        path = File.join(Storages.base_route, id)
        result = client.patch(
          path: path,
          body: storage.to_json,
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        updated = Model::Storage.from_trusted_json(result.body)

        updated.id.should eq storage.id
        updated.bucket_name.should_not eq original_name
        updated.mime_filter.should eq(["image/bmp", "image/jpeg", "image/tiff"])
        updated.ext_filter.should eq(["bmp", "jpg", "tiff"])
        updated.destroy
      end

      it "show" do
        Model::Storage.clear
        model = PlaceOS::Model::Generator.storage.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = client.get(
          path: File.join(Storages.base_route, id.to_s),
          headers: Spec::Authentication.headers,
        )

        result.status_code.should eq 200
        response_model = Model::Storage.from_trusted_json(result.body)
        response_model.id.should eq id

        model.destroy
      end

      it "destroy" do
        Model::Storage.clear
        model = PlaceOS::Model::Generator.storage.save!
        model.persisted?.should be_true
        id = model.id.as(String)
        result = client.delete(
          path: File.join(Storages.base_route, id.to_s),
          headers: Spec::Authentication.headers
        )

        result.success?.should eq true
        Model::Storage.find?(id).should be_nil
      end
    end
  end
end
