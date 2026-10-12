require "./image_gen"
require "./llm/types"
require "./llm/schema"
require "./llm/prompt"
require "./llm/ops"
require "./llm/adapter"
require "./llm/adapters/openai_chat"
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

    # shared across the process, sized by MAP_AI_MAX_CALLS, apart from the
    # image slots so a burst of map edits cannot starve poster generation
    class_getter slots : ImageGen::Slots { ImageGen::Slots.new(MAP_AI_MAX_CALLS) }
  end
end
