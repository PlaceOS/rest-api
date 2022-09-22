module PlaceOS::Api::SpecClient
  # Can't use ivars at top level, hence this hack
  private CLIENT = ActionController::SpecHelper.client

  def client
    CLIENT
  end
end
