module PlaceOS::Api::Utils::History
  macro model_history(current_model, id_param = nil, &transform)
    {% id = id_param || DEFAULT_PARAM_ID[@type.id] || :id %}

    getter offset : Int32 do
      params["offset"]?.try(&.to_i) || 0
    end

    getter limit : Int32 do
      params["limit"]?.try(&.to_i) || 15
    end

    # Returns history for a resource
    #
    get "/{{ id.id }}/history", :history do
      history = {{ current_model }}.history(offset: offset, limit: limit)

      {% if transform %}
        history = {{ yield }}
      {% end %}

      total = {{ current_model }}.history_count
      range_start = offset
      range_end = history.size + range_start

      response.headers["X-Total-Count"] = total.to_s
      response.headers["Content-Range"] = "sets #{range_start}-#{range_end}/#{total}"

      # Set link
      if range_end < total
        params["offset"] = (range_end + 1).to_s
        params["limit"] = limit.to_s
        path = File.join(base_route, "/#{{{ current_model }}.id}/history")
        response.headers["Link"] = %(<#{path}?#{query_params}>; rel="next")
      end

      render json: history
    end
  end
end
