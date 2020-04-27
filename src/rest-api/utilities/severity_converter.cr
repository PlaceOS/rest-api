require "log"

# Serialization for severity fields of models
module SeverityConverter
  def self.to_json(value : Log::Severity, json : JSON::Builder)
    json.string(value.to_s.downcase)
  end

  def self.from_json(value : JSON::PullParser) : Log::Severity
    Log::Severity.new(value)
  end
end
