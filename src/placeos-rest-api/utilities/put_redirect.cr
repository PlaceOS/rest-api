module PlaceOS::Api::Utils::PutRedirect
  macro put_redirect
    {% if @type.has_method?(:update) %}
      put "/{{DEFAULT_PARAM_ID[@type.id] || :id}}", :update_alt { update }
    {% else %}
      {% raise "`update` is not present on #{@type.id}" %}
    {% end %}
  end
end
