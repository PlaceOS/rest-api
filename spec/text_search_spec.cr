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

      it "cannot confuse literal input with the email handling (Greptile P2 on #446)" do
        # the single-pass tokenizer has no placeholder namespace to collide with
        Utils::TextSearch.tsquery("adele@example.com placeosemailtoken0x")
          .should eq "'adele@example.com' | placeosemailtoken0x:*"
        # an email immediately followed by a colon is not mistaken for a field prefix
        Utils::TextSearch.tsquery("adele@example.com: hello")
          .should eq "'adele@example.com' | hello:*"
      end

      it "matches dotted room numbers as a unit rather than OR-splitting them" do
        # "4 | 23" never matched "Darwin City 4.23 Classroom" (indexed as the
        # single lexeme '4.23') yet matched every record containing a bare "4"
        Utils::TextSearch.tsquery("4.23").should eq "('4.23':* | 4 <-> 23:*)"
        Utils::TextSearch.tsquery("4.23 classroom").should eq "('4.23' | 4 <-> 23) | classroom:*"
        Utils::TextSearch.tsquery("darwin 4.23").should eq "darwin | ('4.23':* | 4 <-> 23:*)"
        Utils::TextSearch.tsquery("L4.23").should eq "('L4.23':* | L4 <-> 23:*)"
        Utils::TextSearch.tsquery("4.23.1").should eq "('4.23.1':* | 4 <-> 23 <-> 1:*)"
      end

      it "matches identifiers joined by hyphens, underscores and slashes as a unit" do
        Utils::TextSearch.tsquery("sys-abc123").should eq "('sys-abc123':* | sys <-> abc123:*)"
        Utils::TextSearch.tsquery("4-23").should eq "('4-23':* | 4 <-> 23:*)"
        Utils::TextSearch.tsquery("video_switcher").should eq "('video_switcher':* | video <-> switcher:*)"
        Utils::TextSearch.tsquery("place/video").should eq "('place/video':* | place <-> video:*)"
      end

      it "drops dangling separators while a compound term is being typed" do
        Utils::TextSearch.tsquery("4.").should eq "4:*"
        Utils::TextSearch.tsquery("sys-").should eq "sys:*"
        Utils::TextSearch.tsquery(".23").should eq "23:*"
        Utils::TextSearch.tsquery("4..23").should eq "4 | 23:*"
      end

      it "keeps emails and field prefixes ahead of compound terms" do
        Utils::TextSearch.tsquery("first.last@example.com 4.23")
          .should eq "'first.last@example.com' | ('4.23':* | 4 <-> 23:*)"
        Utils::TextSearch.tsquery("tags:(+level) building.zone")
          .should eq "level | ('building.zone':* | building <-> zone:*)"
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

      it "always produces a tsquery PostgreSQL accepts" do
        inputs = [
          "4.23", "L4.23", "4-23", "4/23", "4.23a", "-4.23-", "a.b.c/d-e_f",
          "it's 4.23", %(4.23\\ 'x'), "o'brien.smith", "4.23 & !x | (y)", "café.ünï-23",
          "first.last@example.com", "tags:(+level AND +building)", "4.23" * 200,
        ]
        ::PgORM::Database.connection do |conn|
          inputs.each do |input|
            tsq = Utils::TextSearch.tsquery(input).not_nil!
            conn.query_one("SELECT to_tsquery('simple', $1)::text", args: [tsq.as(::PgORM::Value)], as: String).should_not be_empty
          end
        end
      end
    end
  end
end
