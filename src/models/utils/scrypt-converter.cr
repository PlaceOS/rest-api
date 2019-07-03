require "json"

module Scrypt::Converter
  def self.from_json(value : JSON::PullParser) : Scrypt::Password
    Scrypt::Password.new(value.read_string)
  end

  def self.to_json(value : Scrypt::Password, json : JSON::Builder)
    json.string(value.to_s)
  end

  def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : Scrypt::Password
    unless node.is_a?(YAML::Nodes::Scalar)
      node.raise "Expected scalar, not #{node.class}"
    end
    Scrypt::Password.new(node.value.to_s)
  end

  def self.to_yaml(value : Scrypt::Password, yaml : YAML::Nodes::Builder)
    yaml.scalar(value.to_s)
  end
end
