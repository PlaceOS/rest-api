require "./image_gen/types"
require "./image_gen/http"
require "./image_gen/prompt"
require "./image_gen/slots"
require "./image_gen/adapter"
require "./image_gen/adapters/openai_images"
require "./image_gen/adapters/gemini_vertex"
require "./image_gen/store"
require "./image_gen/runner"
require "./image_gen/sweep"

module PlaceOS::Api
  # Image generation for signage artwork.
  #
  # A request handler validates, reserves slots and writes a job row, then hands
  # off to `Runner` in a spawned fiber. Candidates are stored through the same
  # `Storage` and `Upload` machinery the uploads controller uses, and written
  # back into the job row one at a time so a long polling client sees each one
  # as it lands.
  #
  # Nothing in here touches `request`: the fiber outlives it.
  module ImageGen
    Log = ::Log.for(self)

    # sizes we ask a vendor for, by aspect. gpt-image-2 needs both edges to be a
    # multiple of 16, which is why the landscape size is 2048x1152 and not
    # 1920x1080. Players scale to the panel.
    SIZES = {
      "16:9" => {2048, 1152},
      "9:16" => {1152, 2048},
      "1:1"  => {2048, 2048},
      "4:3"  => {2048, 1536},
    }

    ASPECTS = SIZES.keys

    QUALITIES = ["standard", "high"]

    MAX_CANDIDATES = 4

    def self.aspect_valid?(aspect : String) : Bool
      SIZES.has_key?(aspect)
    end

    def self.size_for(aspect : String) : Tuple(Int32, Int32)
      SIZES[aspect]? || SIZES["16:9"]
    end

    # gpt-image-2 accepts any size with both edges a multiple of 16, a long edge
    # no greater than 3840, a ratio within 3:1, and between 655,360 and
    # 8,294,400 total pixels.
    MIN_PIXELS =   655_360
    MAX_PIXELS = 8_294_400
    MAX_EDGE   =     3_840
    MAX_RATIO  =       3.0

    # The size to ask for when editing: the source's own shape, snapped to what
    # the vendor accepts. An edit must not reframe the image, and the aspect the
    # caller picked describes where the poster will play, not what shape the
    # thing they handed us is.
    def self.editable_size(width : Int32, height : Int32) : String?
      return nil if width <= 0 || height <= 0

      w = width.to_f
      h = height.to_f

      # a shape the vendor will not draw at all: fall back to the aspect table
      return nil if (w / h) > MAX_RATIO || (h / w) > MAX_RATIO

      # scale into the pixel budget, then off the longest edge
      pixels = w * h
      scale = 1.0
      scale = Math.sqrt(MAX_PIXELS / pixels) if pixels > MAX_PIXELS
      scale = Math.sqrt(MIN_PIXELS / pixels) if pixels < MIN_PIXELS
      w *= scale
      h *= scale

      longest = Math.max(w, h)
      if longest > MAX_EDGE
        edge_scale = MAX_EDGE / longest
        w *= edge_scale
        h *= edge_scale
      end

      # both edges to a multiple of 16, keeping at least the minimum pixels
      snapped_w = ((w / 16).round * 16).to_i
      snapped_h = ((h / 16).round * 16).to_i
      snapped_w = 16 if snapped_w < 16
      snapped_h = 16 if snapped_h < 16

      # snapping moves the area either way, and both bounds are hard: nudge a
      # step at a time until it sits inside them
      while snapped_w * snapped_h < MIN_PIXELS
        if snapped_w < snapped_h
          snapped_w += 16
        else
          snapped_h += 16
        end
      end

      while snapped_w * snapped_h > MAX_PIXELS && snapped_w > 16 && snapped_h > 16
        if snapped_w > snapped_h
          snapped_w -= 16
        else
          snapped_h -= 16
        end
      end

      return nil if snapped_w > MAX_EDGE || snapped_h > MAX_EDGE
      return nil if snapped_w * snapped_h < MIN_PIXELS || snapped_w * snapped_h > MAX_PIXELS
      "#{snapped_w}x#{snapped_h}"
    end

    # shared across the process, sized by SIGNAGE_AI_MAX_CALLS
    class_getter slots : Slots { Slots.new(SIGNAGE_AI_MAX_CALLS) }
  end
end
