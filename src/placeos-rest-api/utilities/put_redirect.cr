module PlaceOS::Api::Utils::PutRedirect
  macro included
    macro inherited
      {% if @type.has_method?(:update) %}
        put "/{{DEFAULT_PARAM_ID[@type.id] || :id}}", :update_alt { update }
      {% end %}
    end
  end
end
