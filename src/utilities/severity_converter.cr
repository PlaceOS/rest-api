require "logger"

# Serialization for severity fields of models
module SeverityConverter
  def self.to_json(value : Logger::Severity, json : JSON::Builder)
    json.string(value.to_s.downcase)
  end

  def self.from_json(value : JSON::PullParser) : Logger::Severity
    Logger::Severity.new(value)
  end
end
