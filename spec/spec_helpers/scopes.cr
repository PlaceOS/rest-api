require "../helper"

module PlaceOS::Api::Scopes
  extend self

  def show(base, id, scoped_authorization_header)
    client.get(
      path: File.join(base, id),
      headers: scoped_authorization_header,
    )
  end

  def index(path, scoped_authorization_header)
    client.get(
      path: path,
      headers: scoped_authorization_header,
    )
  end

  def create(path, body, scoped_authorization_header)
    client.post(
      path: path,
      body: body,
      headers: scoped_authorization_header,
    )
  end

  def delete(base, id, scoped_authorization_header)
    client.delete(
      path: File.join(base, id),
      headers: scoped_authorization_header,
    )
  end

  def update(path, body, scoped_authorization_header)
    client.patch(
      path: path,
      body: body.to_json,
      headers: scoped_authorization_header,
    )
  end
end
