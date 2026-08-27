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

    # shared across the process, sized by SIGNAGE_AI_MAX_CALLS
    class_getter slots : Slots { Slots.new(SIGNAGE_AI_MAX_CALLS) }
  end
end
