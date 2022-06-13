require "../helper"

module PlaceOS::Api::Scopes
  extend self

  def show(base, id, scoped_headers)
    client.get(
      path: File.join(base, id),
      headers: scoped_headers,
    )
  end

  def index(path, scoped_headers)
    client.get(
      path: path,
      headers: scoped_headers,
    )
  end

  def create(path, body, scoped_headers)
    client.post(
      path: path,
      body: body,
      headers: scoped_headers,
    )
  end

  def delete(base, id, scoped_headers)
    client.delete(
      path: File.join(base, id),
      headers: scoped_headers,
    )
  end

  def update(path, body, scoped_headers)
    client.patch(
      path: path,
      body: body.to_json,
      headers: scoped_headers,
    )
  end
end
