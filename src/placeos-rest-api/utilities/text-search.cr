module PlaceOS::Api
  # PPT-2644: translates the free-form `q` search param into a PostgreSQL
  # tsquery matched against the generated `search_vector` columns
  # (see placeos-models migration 20260810100500000).
  #
  # Guarantees:
  # - never raises, and the output can never produce a tsquery syntax error:
  #   emitted tokens contain only letters/digits joined with `:*` and `|`
  # - Elasticsearch-era query syntax that clients still send (field prefixes
  #   like `tags:(+level AND +building)`, boolean operators, quotes, wildcards)
  #   degrades gracefully into plain terms instead of erroring
  # - token semantics mirror the old Elasticsearch simple_query_string
  #   exactly: tokens are OR-joined whole-word matches, with the FINAL token
  #   a prefix match (Neuroplastic appended `*` to the query's last token) —
  #   so a record matches when ANY term matches, and the term being typed
  #   still autocompletes
  # - compound terms like room numbers ("4.23", "L4.23", "sys-abc123") are
  #   matched as a unit rather than OR-split into their parts
  module Utils::TextSearch
    extend self

    # ES-era boolean operators users/UIs may still include as literal words
    OPERATOR_WORDS = {"and", "or", "not"}

    MAX_QUERY_CHARS = 512
    MAX_TOKENS      =  16

    # Email addresses are kept as a single (quoted) lexeme rather than being
    # split: the search vectors index every address both whole and tokenized,
    # and whole-address matching is what preserves the precise user-lookup
    # behavior clients had via the old field-scoped email phrase match —
    # OR-splitting an address would match everyone on the same domain.
    # The character class cannot match `'` or `\`, so the quoted lexeme can
    # never break out of the tsquery syntax.
    EMAIL = /[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[\p{L}]{2,}/

    # Alphanumeric runs joined by `.`, `-`, `_` or `/`, e.g. room numbers like
    # "4.23" or "L4.23". PostgreSQL's parser indexes many of these as a single
    # lexeme ('4.23'), so OR-splitting them (`4 | 23`) could never match the
    # intended record while matching every record containing a bare "4".
    COMPOUND = /[\p{L}\p{N}]+(?:[._\/-][\p{L}\p{N}]+)+/

    COMPOUND_SEPARATORS = /[._\/-]/

    # One ordered pass over the input: capture whole email addresses, consume
    # `field:` prefixes (Backoffice's zone tag filter sends ES syntax like
    # `tags:(+level AND +building)`) without emitting them, and collect
    # compound and plain word tokens. A single scan means no intermediate
    # placeholder text, so no user-typed input can collide with the email
    # handling.
    TOKENIZER = /(#{EMAIL.source})|[\w.]+\s*:|(#{COMPOUND.source})|([\p{L}\p{N}]+)/

    private enum Kind
      Email
      Compound
      Word
    end

    # Builds the argument for `to_tsquery('simple', ?)` from user input, or
    # returns `nil` when the input imposes no text filter (nil / blank / "*" /
    # nothing searchable) — ES treated those as match-all.
    def tsquery(q : String?) : String?
      return nil if q.nil?
      q = q[0, MAX_QUERY_CHARS] if q.size > MAX_QUERY_CHARS

      tokens = [] of {Kind, String}
      q.scan(TOKENIZER) do |match|
        break if tokens.size >= MAX_TOKENS
        if address = match[1]?
          tokens << {Kind::Email, address}
        elsif compound = match[2]?
          tokens << {Kind::Compound, compound}
        elsif word = match[3]?
          tokens << {Kind::Word, word} unless OPERATOR_WORDS.includes?(word.downcase)
        end
      end

      return nil if tokens.empty?
      last = tokens.size - 1
      tokens.map_with_index { |(kind, text), i| term(kind, text, i == last) }.join(" | ")
    end

    private def term(kind : Kind, text : String, prefix : Bool) : String
      suffix = prefix ? ":*" : ""
      case kind
      in .email?
        "'#{text}'#{suffix}"
      in .word?
        "#{text}#{suffix}"
      in .compound?
        # Quoting makes to_tsquery run the term through the same parser that
        # built the search vectors, so it matches however PostgreSQL indexed
        # it ('4.23', 'l4.23', '4' <-> '-23'). The phrase of its parts also
        # matches the same words written with other separators or spaces
        # ("meeting-room" finds "Meeting Room"). COMPOUND can't match `'` or
        # `\`, so the quoted lexeme can never break out of the tsquery syntax.
        "('#{text}'#{suffix} | #{text.split(COMPOUND_SEPARATORS).join(" <-> ")}#{suffix})"
      end
    end
  end
end
