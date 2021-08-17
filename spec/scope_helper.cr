require "../lib/action-controller/spec/curl_context"

def show_route(base, id, authorization_header)
  curl(
    method: "GET",
    path: base + id,
    headers: authorization_header,
  )
end

def index_route(base, authorization_header)
  curl(
    method: "GET",
    path: base,
    headers: authorization_header.merge({"Content-Type" => "application/json"}),
  )
end

def create_route(base, body, authorization_header)
  curl(
    method: "POST",
    path: base,
    body: body,
    headers: authorization_header.merge({"Content-Type" => "application/json"}),
  )
end

def delete_route(base, id, authorization_header)
  curl(
    method: "DELETE",
    path: base + id,
    headers: authorization_header,
  )
end
