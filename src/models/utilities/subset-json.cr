require "json"

# Create a serialisation method with subset defined by fields
# Pass a serialise method to fields if the field class does not define a to_json method
# method_name : Symbol
# fields      : Enumerable(Symbol | NamedTuple(field: Symbol, serialise: Symbol))
macro subset_json(method_name, fields)
 {% fields = fields.resolve if fields.is_a?(Path) %}
  def {{ method_name.id }}
    {
      {% for field in fields %}
        {% if field.is_a?(NamedTupleLiteral) %}
          {{ field[:field].id }}: self.{{ field[:field].id }}.try &.{{ field[:serialise].id }},
        {% elsif field.is_a?(SymbolLiteral) %}
          {{ field.id }}: self.{{ field.id }},
        {% else %}
          {{ raise "expected Enumerable(Symbol | NamedTuple(field: Symbol, serialise: Symbol)), got element #{field}" }}
        {% end %}
      {% end %}
    }.to_json
  end
end
