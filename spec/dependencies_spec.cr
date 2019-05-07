require "./helper"

module Engine::API
  pending Dependencies do
    with_server do
      test_404(namespace: Dependencies::NAMESPACE, model_name: Model::Dependency.table_name)
      test_crud(klass: Model::Dependency, controller_klass: Dependencies)
      pending "index"
    end
  end
end
