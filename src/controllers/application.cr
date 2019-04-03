require "../utils"

abstract class Application < ActionController::Base
  rescue_from RethinkORM::Error::DocumentNotFound do
    head :not_found
  end

  NAME_SORT_ASC = [{"doc.name.sort" => {order: :asc}}]
end
