require "placeos-compiler"

PRIVATE_DRIVER_ID = "driver-#{random_id}"

def random_id
  UUID.random.to_s.split('-').first
end

def set_temporary_working_directory(fresh : Bool = false, path : String? = nil) : String
  temp_dir = "#{Dir.tempdir}/core-spec-#{random_id}"
  temp_dir = Path[path].expand.to_s if path
  PlaceOS::Compiler.binary_dir = "#{temp_dir}/bin"
  PlaceOS::Compiler.repository_dir = "#{temp_dir}/repositories"

  Dir.mkdir_p(File.join(PlaceOS::Compiler.binary_dir, "drivers"))
  Dir.mkdir_p(PlaceOS::Compiler.repository_dir)

  temp_dir
end

def setup_system
  # Repository metadata
  repository_uri = "https://github.com/placeos/private-drivers"
  repository_name = "Private Drivers"
  repository_folder_name = "private-drivers"

  # Driver metadata
  driver_file_name = "drivers/place/private_helper.cr"
  driver_module_name = "PrivateHelper"
  driver_name = "spec_helper"
  driver_commit = "HEAD"
  driver_role = PlaceOS::Model::Driver::Role::Logic

  repository = PlaceOS::Model::Generator.repository(type: PlaceOS::Model::Repository::Type::Driver)
  repository.uri = repository_uri
  repository.name = repository_name
  repository.folder_name = repository_folder_name
  repository.save!

  driver = PlaceOS::Model::Driver.new(
    name: driver_name,
    role: driver_role,
    commit: driver_commit,
    module_name: driver_module_name,
    file_name: driver_file_name,
  )
  driver._new_flag = true
  driver.id = PRIVATE_DRIVER_ID
  driver.repository = repository
  driver.save!

  mod = PlaceOS::Model::Generator.module(driver: driver)
  mod.running = true
  mod.save!

  control_system = PlaceOS::Model::Generator.control_system.save!

  mod.control_system = control_system

  control_system.modules = [mod.id.as(String)]
  control_system.save

  {driver, repository, mod, control_system}
end
