require "./application"
require "qr-code"
require "qr-code/export/png"

module PlaceOS::Api
  class ShortURL < Application
    include Utils::Permissions

    base "/api/engine/v2/short_url"

    # Scopes
    ###############################################################################################

    before_action :can_read, only: [:index, :show]
    before_action :can_write, only: [:create, :update, :destroy]

    ###############################################################################################

    @[AC::Route::Filter(:before_action, except: [:index, :create])]
    def current_url(id : String)
      Log.context.set(url_id: id)
      # Find will raise a 404 (not found) if there is an error
      @current_url = url = Model::Shortener.find!(id)

      # ensure the current user has access
      raise Error::Forbidden.new unless authority.id == url.authority_id
    end

    getter! current_url : Model::Shortener

    @[AC::Route::Filter(:before_action, only: [:update, :create], body: :url_update)]
    def parse_update_url(@url_update : Model::Shortener)
    end

    getter! url_update : Model::Shortener

    getter authority : Model::Authority { current_authority.as(Model::Authority) }

    # Permissions
    ###############################################################################################

    @[AC::Route::Filter(:before_action, only: [:destroy, :update, :create])]
    def check_access_level
      return if user_support?

      # find the org zone
      org_zone_id = authority.config["org_zone"]?.try(&.as_s?)
      raise Error::Forbidden.new unless org_zone_id

      access = check_access(current_user.groups, [org_zone_id])
      return if access.can_manage?

      raise Error::Forbidden.new
    end

    ###############################################################################################

    # list the short URLs for this domain
    @[AC::Route::GET("/")]
    def index : Array(Model::Shortener)
      elastic = Model::Shortener.elastic
      query = elastic.query(search_params)
      query.filter({
        "authority_id" => [authority.id.as(String)],
      })
      query.search_field "name"
      query.sort({"created_at" => {order: :desc}})
      paginate_results(elastic, query)
    end

    # return the details of the requested shortened URL
    @[AC::Route::GET("/:id")]
    def show : Model::Shortener
      current_url
    end

    # update the details of a short URL
    @[AC::Route::PATCH("/:id")]
    @[AC::Route::PUT("/:id")]
    def update : Model::Shortener
      url = url_update
      current = current_url
      current_count = current.redirect_count
      current.assign_attributes(url)
      current.authority_id = authority.id
      current.user = current_user
      current.redirect_count = current_count
      raise Error::ModelValidation.new(current.errors) unless current.save
      current
    end

    # add a new short URL
    @[AC::Route::POST("/", status_code: HTTP::Status::CREATED)]
    def create : Model::Shortener
      url = url_update
      url.authority_id = authority.id
      url.user = current_user
      url.redirect_count = 0_i64
      raise Error::ModelValidation.new(url.errors) unless url.save
      url
    end

    # remove a short URL
    @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
    def destroy : Nil
      current_url.destroy
    end

    # add a redirect path without security
    skip_action :authorize!, only: :redirect
    skip_action :set_user_id, only: :redirect

    # redirects to the URI specified by the provided short URL id
    @[AC::Route::GET("/:id/redirect", status_code: HTTP::Status::SEE_OTHER)]
    def redirect : Nil
      current_url.increment_redirect_count
      response.headers["Location"] = current_url.uri
    end

    # obtains an SVG QR code for the specified short URL
    @[AC::Route::GET("/:id/qr_code.svg")]
    def svg_qr : Nil
      # remove the "uri-" prefix from the id
      id = current_url.id.as(String)[4..-1]
      response.headers["Content-Type"] = "image/svg+xml"
      response.headers["Content-Disposition"] = "inline"

      short_uri = "https://#{request.headers["Host"]}/r/#{id}"
      svg_qr_response short_uri
    end

    # obtains an PNG QR code for the specified short URL with optional resolution
    @[AC::Route::GET("/:id/qr_code.png")]
    def png_qr(
      @[AC::Param::Info(description: "size of the QR code in pixels. Between 72px and 512px")]
      size : Int32 = 256
    ) : Nil
      # remove the "uri-" prefix from the id
      id = current_url.id.as(String)[4..-1]
      size = size.clamp(72, 512)
      size += size % 2 # ensure an even number

      response.headers["Content-Disposition"] = "inline"
      short_uri = "https://#{request.headers["Host"]}/r/#{id}"
      png_qr_response(short_uri, size)
    end

    enum Format
      SVG
      PNG
    end

    # helper for generating QR codes with user defined content
    @[AC::Route::GET("/qr_code")]
    def generate_qr_code(
      @[AC::Param::Info(description: "the contents of the QR code")]
      content : String,
      @[AC::Param::Info(description: "file format of the response")]
      format : Format = Format::SVG,
      @[AC::Param::Info(description: "size of the QR code in pixels. Between 72px and 512px")]
      size : Int32 = 256
    ) : Nil
      response.headers["Content-Disposition"] = "inline"

      case format
      in .svg?
        svg_qr_response content
      in .png?
        png_qr_response(content, size)
      end
    end

    protected def png_qr_response(content : String, size : Int32) : Nil
      response.headers["Content-Type"] = "image/png"
      @__render_called__ = true
      png_bytes = QRCode.new(content).as_png(size: size)
      response.write png_bytes
    end

    protected def svg_qr_response(content : String) : Nil
      response.headers["Content-Type"] = "image/svg+xml"
      @__render_called__ = true
      svg = QRCode.new(content).as_svg
      response << svg
    end
  end
end
