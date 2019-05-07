require "./helper"

module Engine::API
  describe Zones do
    with_server do
      test_404(namespace: Zones::NAMESPACE, model_name: Model::Zone.table_name)
      test_crud(klass: Model::Zone, controller_klass: Zones)
      pending "index"
    end
  end
end
