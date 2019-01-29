
class Welcome < Application
  base "/api/systems/"

  def index
    welcome_text = "You're being trampled by Spider-Gazelle!"
    render json: {welcome: welcome_text}
  end
end
