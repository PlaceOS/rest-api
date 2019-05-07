require "./helper"

module Engine::API
  describe Modules do
    with_server do
      test_404(namespace: Modules::NAMESPACE, model_name: Model::Module.table_name)
      test_crud(klass: Model::Module, controller_klass: Modules)
      pending "index"
    end
  end
end
