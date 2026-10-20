require "./helper"

module PlaceOS::Api
  describe Utils::ModuleLogCapture do
    it "writes lines at or above the level" do
      output = IO::Memory.new
      capture = Utils::ModuleLogCapture.new(output, ::Log::Severity::Info)
      capture.write(::Log::Severity::Debug, "ignored")
      capture.write(::Log::Severity::Info, "connected")
      capture.write(::Log::Severity::Error, "failed")

      lines = output.to_s.lines
      lines.size.should eq 2
      lines[0].should match /^\d{4}-\d\d-\d\dT[\d:.]+Z INFO connected$/
      lines[1].should end_with "ERROR failed"
      capture.bytes_written.should eq output.size
    end

    it "stops at the byte limit, noting the truncation" do
      output = IO::Memory.new
      capture = Utils::ModuleLogCapture.new(output, max_bytes: 200_i64)
      10.times { |index| capture.write(::Log::Severity::Info, "message #{index}") }

      output.to_s.should end_with Utils::ModuleLogCapture::TRUNCATED
      output.size.should be <= 200
      capture.finished?.should be_true

      # the capture ends straight away
      elapsed = Time.measure { capture.wait(5.seconds) }
      elapsed.should be < 1.second
    end

    it "stops when the output fails" do
      reader, writer = IO.pipe
      reader.close
      capture = Utils::ModuleLogCapture.new(writer)
      capture.write(::Log::Severity::Info, "client gone")
      capture.finished?.should be_true
      Time.measure { capture.wait(5.seconds) }.should be < 1.second
    ensure
      writer.try &.close
    end

    it "waits for the period, reporting progress" do
      context = ActionController::MCPServer::RequestContext.new(JSON::Any.new("token"))
      capture = Utils::ModuleLogCapture.new(IO::Memory.new)
      elapsed = Time.measure { capture.wait(300.milliseconds, context) }
      elapsed.should be >= 300.milliseconds
      elapsed.should be < 2.seconds
      capture.finished?.should be_true
    end

    it "ends when the MCP request is cancelled" do
      context = ActionController::MCPServer::RequestContext.new
      capture = Utils::ModuleLogCapture.new(IO::Memory.new)
      spawn do
        sleep 100.milliseconds
        context.cancel
      end
      Time.measure { capture.wait(5.seconds, context) }.should be < 2.seconds
    end

    it "ends when stopped, i.e. core closed the debug socket" do
      capture = Utils::ModuleLogCapture.new(IO::Memory.new)
      spawn do
        sleep 100.milliseconds
        capture.stop
      end
      Time.measure { capture.wait(5.seconds) }.should be < 2.seconds
    end
  end
end
