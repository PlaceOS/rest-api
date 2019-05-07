require "./helper"

module Engine::API
  describe Systems do
    with_server do
      test_404(namespace: Systems::NAMESPACE, model_name: Model::ControlSystem.table_name)
      test_crud(klass: Model::ControlSystem, controller_klass: Systems)
      pending "index"
    end
  end
end
