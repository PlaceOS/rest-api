require "./helper"

module Engine::API
  describe Drivers do
    with_server do
      test_404(namespace: Drivers::NAMESPACE, model_name: Model::Driver.table_name)
      test_crud(klass: Model::Driver, controller_klass: Drivers)
      pending "index"
    end
  end
end
