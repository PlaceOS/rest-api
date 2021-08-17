require "./helper"
require "./scopes"

module PlaceOS::Api
  base = Zones::NAMESPACE[0]

  with_server do
    WebMock.reset
    WebMock.allow_net_connect = true

    describe "default public scope" do
      test_crd(klass: Model::Zone, controller_klass: Zones)
    end

    controllers = {Model::Repository => Repositories, Model::Settings => Settings}
    describe "runs scopes" do
      # controllers.each do |klass, controller_klass|
      #   test_scope(klass, controller_klass)
      # end
      # test_scope(Model::Zone, Zones)
      test_scope({Model::Repository => Repositories, Model::Settings => Settings})
    end

    # extra tests for particular  ase i.e. metadata
  end
end
