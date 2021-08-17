require "./scope_helper"

module PlaceOS::Api
  macro test_scope(hash)
      {% for klass, controller_klass in hash %}
        {% klass_name = klass.stringify.split("::").last.underscore %}
        base = {{ controller_klass }}::NAMESPACE[0]
        context "write" do
            _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("{{ controller_klass.stringify }}".downcase, PlaceOS::Model::UserJWT::Scope::Access::Write)])

            it "should not allow access to show" do
              model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
              model.persisted?.should be_true
              id = model.id.as(String)
              result = show_route(base, id, authorization_header)
              result.success?.should be_false
              model.destroy
            end

            it "should not allow access to index" do
              result = index_route(base, authorization_header)
              result.success?.should be_false
            end

            it "should allow access to create" do
              body = PlaceOS::Model::Generator.{{ klass_name.id }}.to_json
              result = create_route(base, body, authorization_header)
              result.success?.should be_true

              body = result.body.as(String)
              response_model = {{ klass.id }}.from_trusted_json(result.body)
              response_model.destroy
            end

            it "should  allow access to delete" do
              model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
              model.persisted?.should be_true
              id = model.id.as(String)
              result = delete_route(base, id, authorization_header)
              result.success?.should be_true
              {{ klass.id }}.find(id).should be_nil
            end
        end
        
        context "read" do
          _, authorization_header = authentication(scope: [PlaceOS::Model::UserJWT::Scope.new("{{ klass_name.id }}", PlaceOS::Model::UserJWT::Scope::Access::Read)])

          it "allows access to show" do
            model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
            model.persisted?.should be_true
            id = model.id.as(String)
            result = show_route(base, id, authorization_header)
            result.status_code.should eq 200
            response_model = {{ klass.id }}.from_trusted_json(result.body)
            response_model.id.should eq id
            model.destroy
          end

          it "allows access to index" do
            result = index_route(base, authorization_header)
            result.success?.should be_true
          end

          it "should not allow access to create" do
            body = PlaceOS::Model::Generator.{{ klass_name.id }}.to_json
            result = create_route(base, body, authorization_header)
            result.success?.should be_false
          end

          it "should not allow access to delete" do
            model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
            model.persisted?.should be_true
            id = model.id.as(String)
            result = delete_route(base, id, authorization_header)
            result.success?.should be_false
            {{ klass.id }}.find(id).should_not be_nil
          end 
      end
    {% end %}
  end
end
