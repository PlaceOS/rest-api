module PlaceOS::Api
  # PPT-2644: translates the free-form `q` search param into a PostgreSQL
  # tsquery matched against the generated `search_vector` columns
  # (see placeos-models migration 20260806100500000).
  #
  # Guarantees:
  # - never raises, and the output can never produce a tsquery syntax error:
  #   emitted tokens contain only letters/digits joined with `:*` and `&`
  # - Elasticsearch-era query syntax that clients still send (field prefixes
  #   like `tags:(+level AND +building)`, boolean operators, quotes, wildcards)
  #   degrades gracefully into plain terms instead of erroring
  # - every token is a prefix match (parity with the trailing `*` the old
  #   Neuroplastic layer appended to every query); tokens are ANDed, which is
  #   equal-or-stricter than the old OR and matches what autocomplete UIs
  #   expect (they intersect results client-side)
  module Utils::TextSearch
    extend self

    # ES-era boolean operators users/UIs may still include as literal words
    OPERATOR_WORDS = {"and", "or", "not"}

    MAX_QUERY_CHARS = 512
    MAX_TOKENS      =  16

    # Builds the argument for `to_tsquery('simple', ?)` from user input, or
    # returns `nil` when the input imposes no text filter (nil / blank / "*" /
    # nothing searchable) — ES treated those as match-all.
    def tsquery(q : String?) : String?
      return nil if q.nil?
      q = q[0, MAX_QUERY_CHARS] if q.size > MAX_QUERY_CHARS

      # drop `field:` prefixes (Backoffice's zone tag filter sends ES syntax
      # like `tags:(+level AND +building)`)
      text = q.gsub(/[\w.]+\s*:/, ' ')

      tokens = text
        .split(/[^\p{L}\p{N}]+/, remove_empty: true)
        .reject { |token| OPERATOR_WORDS.includes?(token.downcase) }
        .first(MAX_TOKENS)

      return nil if tokens.empty?
      tokens.join(" & ") { |token| "#{token}:*" }
    end
  end
end
