require "json"
require "semantic_version"

# Reopen the SemanticVersion class
struct SemanticVersion
  # Allows serialization to rethinkDB query language
  def to_reql
    JSON::Any.new(self.to_s)
  end
end

# Serialization for SemanticVersion fields of models
module SemanticVersion::Converter
  def self.from_json(value : JSON::PullParser) : SemanticVersion
    SemanticVersion.parse(value.read_string)
  end

  def self.to_json(value : SemanticVersion, json : JSON::Builder)
    json.string(value.to_s)
  end

  def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : SemanticVersion
    unless node.is_a?(YAML::Nodes::Scalar)
      node.raise "Expected scalar, not #{node.class}"
    end
    SemanticVersion.parse(node.value.to_s)
  end

  def self.to_yaml(value : SemanticVersion, yaml : YAML::Nodes::Builder)
    yaml.scalar(value.to_s)
  end
end
