require "../constants"
require "../error"
require "../utils"

abstract class Params < ActiveModel::Model
  # Checks that the model is valid
  # Responds with the validation errors
  def validate_params!
    unless self.valid?
      render status: :not_acceptable, json: self.errors
    end
  end
end

class UserMock
  @mocks = {} of Symbol => String | Bool | Int32 | Float32

  def initialise(@mocks = {
                   :logged_in? => true,
                   :sys_admin  => true,
                 })
  end

  def logged_in?
    mocks[:logged_in?]
  end

  def sys_admin
    mocks[:sys_admin]
  end
end

abstract class Application < ActionController::Base
  NAME_SORT_ASC = [{"doc.name.sort" => {order: :asc}}]

  rescue_from RethinkORM::Error::DocumentNotFound do |error| # ameba:disable Lint/UnusedArgument
    head :not_found
  end

  rescue_from Error::ParameterMissing do |error|
    render status: :unprocessable_entity, text: error.message
  end

  # Authentication through JWT
  # TODO: Mock
  def current_user
    UserMock.new
  end

  # Shortcut to save a record and render a response
  def save_and_respond(resource)
    creation = resource.new_record?
    if resource.save
      # TODO: ActionController does not accept variable status to render
      creation ? render json: resource, status: :created : render json: resource, status: :ok
    else
      render json: resource.errors.map(&.to_s), status: :unprocessable_entity
    end
  end
end
