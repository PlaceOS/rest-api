require "./helper"

module PlaceOS::Api
  describe Llm::Adapters::AnthropicMessages do
    it "rejects missing, unexpected, malformed and multiple proposal tool calls" do
      row = Model::Generator.signage_ai_provider(provider: Model::SignageAIProvider::Provider::ANTHROPIC)
      row.credentials_json = {"api_key" => JSON::Any.new("test-key")}
      adapter = Llm::Adapters::AnthropicMessages.new(row)
      request = Llm::Request.new(system: "x", parts: [Llm::TextPart.new("x")] of Llm::Part,
        model: "claude-fable-5-1", max_output_tokens: 100, schema: Llm::Schema.openai)
      [
        %([{"type":"text","text":"no proposal"}]),
        %([{"type":"tool_use","name":"other","input":{}}]),
        %([{"type":"tool_use","name":"map_edit","input":"invalid"}]),
        %([{"type":"tool_use","name":"map_edit","input":{}},{"type":"tool_use","name":"map_edit","input":{}}]),
      ].each do |blocks|
        WebMock.reset
        WebMock.stub(:post, HttpMocks::ANTHROPIC_MESSAGES).to_return(
          status: 200, body: %({"stop_reason":"tool_use","content":#{blocks}}))
        expect_raises(Error::ImageGen::InvalidResponse, "the model did not return one map_edit tool result") do
          adapter.complete(request)
        end
      end
    end

    it "reports a proposal cut off at max_tokens as length so the runner can retry" do
      row = Model::Generator.signage_ai_provider(provider: Model::SignageAIProvider::Provider::ANTHROPIC)
      row.credentials_json = {"api_key" => JSON::Any.new("test-key")}
      adapter = Llm::Adapters::AnthropicMessages.new(row)
      request = Llm::Request.new(system: "x", parts: [Llm::TextPart.new("x")] of Llm::Part,
        model: "claude-fable-5-1", max_output_tokens: 100, schema: Llm::Schema.openai)
      [
        %([{"type":"text","text":"Working through the labels first"}]),
        %([{"type":"tool_use","name":"map_edit","input":{"schema_version":1,"summary":"Renames"}}]),
      ].each do |blocks|
        WebMock.reset
        WebMock.stub(:post, HttpMocks::ANTHROPIC_MESSAGES).to_return(
          status: 200, body: %({"stop_reason":"max_tokens","content":#{blocks}}))
        result = adapter.complete(request)
        result.finish.should eq "length"
        result.text.should eq ""
      end
    end

    it "reads the proposal tool input and ignores accompanying prose" do
      row = Model::Generator.signage_ai_provider(provider: Model::SignageAIProvider::Provider::ANTHROPIC)
      row.credentials_json = {"api_key" => JSON::Any.new("test-key")}
      adapter = Llm::Adapters::AnthropicMessages.new(row)
      request = Llm::Request.new(system: "x", parts: [Llm::TextPart.new("x")] of Llm::Part,
        model: "claude-fable-5-1", max_output_tokens: 100, schema: Llm::Schema.openai)
      proposal = %({"schema_version":1,"summary":"No change","ops":[],"questions":[]})
      WebMock.stub(:post, HttpMocks::ANTHROPIC_MESSAGES).to_return(status: 200,
        body: %({"stop_reason":"tool_use","content":[{"type":"text","text":"Here is the proposal."},{"type":"tool_use","name":"map_edit","input":#{proposal}}]}))
      result = adapter.complete(request)
      JSON.parse(result.text).should eq JSON.parse(proposal)
      result.finish.should eq "stop"
    end
  end
end
