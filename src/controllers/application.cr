require "../utils"
require "../error"

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
  rescue_from RethinkORM::Error::DocumentNotFound do
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

  NAME_SORT_ASC = [{"doc.name.sort" => {order: :asc}}]
end
