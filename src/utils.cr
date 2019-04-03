require "action-controller"

module Utils
  def save_and_respond(resource)
    creation = resource.new_record?
    if resource.save
      status = creation ? :created : :ok
      render json: resource.to_json, status: status
    else
      render json: resource.errors.to_json, status: :unprocessable_entity
    end
  end
end
