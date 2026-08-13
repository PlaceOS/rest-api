require "./helper"

module PlaceOS::Api
  describe Utils::TextSearch do
    describe ".tsquery" do
      it "treats nil, blank and wildcard input as match-all" do
        Utils::TextSearch.tsquery(nil).should be_nil
        Utils::TextSearch.tsquery("").should be_nil
        Utils::TextSearch.tsquery("   ").should be_nil
        Utils::TextSearch.tsquery("*").should be_nil
        Utils::TextSearch.tsquery("& ! | ( ) ~ \" \\").should be_nil
      end

      it "prefix-matches a single token" do
        Utils::TextSearch.tsquery("sydney").should eq "sydney:*"
      end

      it "OR-joins tokens, prefixing only the final one (Elasticsearch parity)" do
        # the old simple_query_string OR-ed terms and Neuroplastic appended
        # `*` to the query's last token only
        Utils::TextSearch.tsquery("sydney room").should eq "sydney | room:*"
        Utils::TextSearch.tsquery("main boardroom 4").should eq "main | boardroom | 4:*"
      end

      it "degrades ES field syntax into plain terms (Backoffice zone tag filter)" do
        Utils::TextSearch.tsquery("tags:(+level AND +building)").should eq "level | building:*"
      end

      it "neutralises ES operators, quotes and boolean words" do
        # `garbage:` reads as a field prefix and is stripped with it
        Utils::TextSearch.tsquery(%(name:(+weird AND "syntax) | garbage:* ~)).should eq "weird | syntax:*"
        Utils::TextSearch.tsquery("name^2 boost").should eq "name | 2 | boost:*"
      end

      it "keeps email addresses as a single quoted lexeme" do
        # OR-splitting an address would match every user on the domain; the
        # whole-address lexeme preserves the old field-scoped precision
        Utils::TextSearch.tsquery("adele@example.onmicrosoft.com").should eq "'adele@example.onmicrosoft.com':*"
        Utils::TextSearch.tsquery("meeting adele@example.com notes").should eq "meeting | 'adele@example.com' | notes:*"
      end

      it "splits hyphenated identifiers" do
        Utils::TextSearch.tsquery("sys-abc123").should eq "sys | abc123:*"
      end

      it "keeps unicode terms without folding" do
        Utils::TextSearch.tsquery("café").should eq "café:*"
      end

      it "caps token count and input length without erroring" do
        many = (1..40).join(' ') { |i| "tok#{i}" }
        query = Utils::TextSearch.tsquery(many).not_nil!
        query.split(" | ").size.should eq Utils::TextSearch::MAX_TOKENS

        Utils::TextSearch.tsquery("x" * 20_000).not_nil!.size.should be <= Utils::TextSearch::MAX_QUERY_CHARS + 2
      end
    end
  end
end
