require "./signage/*"
require "./application"

module PlaceOS::Api
  class Playlist < Application
    include Utils::Permissions

    base "/api/engine/v2/signage"

    # TODO::
    # * configure playlists
    # * get playback info
    # * save statistics
  end
end
