require "placeos-compiler"

PRIVATE_DRIVER_ID = "driver-#{random_id}"

def random_id
  UUID.random.to_s.split('-').first
end

def get_driver
  driver = PlaceOS::Model::Driver.where(name: "spec_helper").first?
  driver, _, _ = setup_system if driver.nil?
  driver
end

def get_sys
  driver = PlaceOS::Model::Driver.where(name: "spec_helper").first?
  if driver.nil?
    _, _, mod, cs = setup_system
  else
    mod = PlaceOS::Model::Module.where(name: driver.module_name).first
    cs = PlaceOS::Model::ControlSystem.where(id: mod.control_system_id).first
  end
  {mod, cs}
end

def setup_system(repository_folder_name = "private-drivers")
  # Repository metadata
  repository_uri = "https://github.com/placeos/private-drivers"
  repository_name = "Private Drivers"

  # Driver metadata
  driver_file_name = "drivers/place/private_helper.cr"
  driver_module_name = "PrivateHelper"
  driver_name = "spec_helper"
  driver_commit = "HEAD"
  driver_role = PlaceOS::Model::Driver::Role::Logic

  repository = PlaceOS::Model::Generator.repository(type: PlaceOS::Model::Repository::Type::Driver)
  repository.uri = repository_uri
  repository.name = repository_name
  repository.folder_name = repository_folder_name + random_id
  repository.save!

  driver = PlaceOS::Model::Driver.new(
    name: driver_name,
    role: driver_role,
    commit: driver_commit,
    module_name: driver_module_name,
    file_name: driver_file_name,
  )
  # driver._new_flag = true
  driver.id = PRIVATE_DRIVER_ID
  driver.repository = repository
  driver.save!

  control_system = PlaceOS::Model::Generator.control_system.save!

  mod = PlaceOS::Model::Generator.module(driver: driver)
  mod.running = true
  mod.save!

  mod.control_system = control_system

  control_system.modules = [mod.id.as(String)]
  control_system.save

  {driver, repository, mod, control_system}
end
