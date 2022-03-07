require "../lib/action-controller/spec/curl_context"

def show_route(base, id, scoped_authorization_header)
  curl(
    method: "GET",
    path: base + id,
    headers: scoped_authorization_header,
  )
end

def index_route(base, scoped_authorization_header)
  curl(
    method: "GET",
    path: base,
    headers: scoped_authorization_header.merge({"Content-Type" => "application/json"}),
  )
end

def create_route(base, body, scoped_authorization_header)
  curl(
    method: "POST",
    path: base,
    body: body,
    headers: scoped_authorization_header.merge({"Content-Type" => "application/json"}),
  )
end

def delete_route(base, id, scoped_authorization_header)
  curl(
    method: "DELETE",
    path: base + id,
    headers: scoped_authorization_header,
  )
end

def update_route(path, body, scoped_authorization_header)
  curl(
    method: "PATCH",
    path: path,
    body: body.to_json,
    headers: scoped_authorization_header.merge({"Content-Type" => "application/json"}),
  )
end
