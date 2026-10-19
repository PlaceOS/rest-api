require "./image_gen"
require "./llm/types"
require "./llm/schema"
require "./llm/values"
require "./llm/prompt"
require "./llm/ops"
require "./llm/adapter"
require "./llm/adapters/openai_chat"
require "./llm/adapters/anthropic_messages"
require "./llm/runner"

module PlaceOS::Api
  # Text/vision model calls for AI map editing, against the signage AI
  # provider rows.
  #
  # A request handler validates, reserves a slot and writes a job row, then
  # hands off to `Runner` in a spawned fiber. The answer is a list of edit
  # operations the editor applies itself; nothing here touches the map.
  module Llm
    Log = ::Log.for(self)

    # the map edit slots, sized by MAP_AI_MAX_CALLS; image calls use `ImageGen.slots`
    class_getter slots : ImageGen::Slots { ImageGen::Slots.new(MAP_AI_MAX_CALLS) }
  end
end
