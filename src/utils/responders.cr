module Engine::API
  module Utils::Responders
    # Shortcut to save a record and render a response
    def save_and_respond(resource)
      creation = resource.new_record?
      if resource.save
        creation ? render json: resource, status: :created : render json: resource, status: :ok
      else
        render json: resource.errors.map(&.to_s), status: :unprocessable_entity
      end
    end

    def with_fields(model, fields)
      attr = JSON.parse(model.to_json).as_h
      attr.merge(fields)
    end

    # Restrict model attributes
    # FIXME: _incredibly_ inefficient, optimise
    # model  : ActiveModel::Model+  base document
    # only   : Array(String)?       attributes to keep
    # except : Array(String)?       attributes to remove
    # fields : Hash?                extra fields to include
    def restrict_attributes(
      model,
      only : Array(String)? = nil,
      except : Array(String)? = nil,
      fields : Hash? = nil
    ) : Hash
      attrs = JSON.parse(model.to_json).as_h
      attrs.select!(only) if only
      attrs.reject!(except) if except
      attrs.merge(fields) if fields

      fields ? attrs.merge(fields) : attrs
    end
  end
end
