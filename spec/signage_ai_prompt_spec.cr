require "./helper"

module PlaceOS::Api
  describe ImageGen::Prompt do
    brand = ImageGen::Prompt::BrandKit.parse(JSON.parse(%({
      "organisation": "Acme",
      "palette": {"primary": "#0E6E52"},
      "tone": "warm, professional",
      "never_include": ["competitor logos"]
    })))

    describe "art direction" do
      it "sends the counter-brief ahead of the brief" do
        prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
          brief: "a poster for the office party",
          aspect: "16:9",
        ))

        prompt.should contain "Avoid the generic"
        prompt.should contain "AVOID:"
        prompt.should contain "purple-blue-orange gradients"
        # the style has to land before the brief, not after it
        prompt.index("Avoid the generic").not_nil!.should be < prompt.index("Brief:").not_nil!
      end

      it "holds back the typography lines when the app is setting the type" do
        prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
          brief: "a poster for the office party",
          aspect: "16:9",
          text_mode: ImageGen::Prompt::TextMode::Layer,
        ))

        # these argue with "leave the top third clear" and with there being no
        # supplied wording at all
        prompt.should_not contain "Typography should feel professionally art-directed"
        prompt.should_not contain "rather than placing text over a generic background"
        prompt.should_not contain "reproduce the supplied wording exactly"

        # but the rest of the direction still applies
        prompt.should contain "Make the layout feel designed rather than algorithmically balanced"
        prompt.should contain "Do not render any text, letters, numbers, words or logos"
      end

      it "includes them when the model is setting the type" do
        prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
          brief: "a poster for the office party",
          aspect: "16:9",
          text_mode: ImageGen::Prompt::TextMode::Model,
        ))

        prompt.should contain "Typography should feel professionally art-directed"
        prompt.should contain "reproduce the supplied wording exactly"
        prompt.should_not contain "Do not render any text"
      end

      it "stays inside a sane prompt length with a brand kit and a refine chain" do
        prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
          brief: "a poster for the office Christmas party on Friday 10 December",
          aspect: "16:9",
          brand: brand,
          history: ["make it warmer", "add paper decorations"],
          instruction: "move the tree left",
        ))

        # gpt-image-2 accepts far more than this, but a runaway prompt would be
        # a cost and a latency problem rather than an error
        prompt.size.should be < 6000
      end
    end

    describe "editing" do
      it "asks for preservation rather than design" do
        prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
          brief: "",
          aspect: "9:16",
          kind: ImageGen::Kind::Edit,
          instruction: %(Make the first "EVENT NAME" text read "PIZZA DAY" instead),
        ))

        prompt.should contain "Make only the change described below"
        prompt.should contain "every typeface, weight, size, casing and text position"
        prompt.should contain "The change to make now, and the only one:"
        prompt.should contain %(read "PIZZA DAY")

        # none of the generation brief: it is what asks for a redesign
        prompt.should_not contain "Avoid the generic"
        prompt.should_not contain "AVOID:"
        prompt.should_not contain "let that idea determine the typography"
        prompt.should_not contain "poster background for a digital signage screen"
        prompt.should_not contain "Do not render any text"
      end

      it "keeps the instruction an instruction on a first edit, not a brief" do
        # the bug this replaced: with no parent job the words were sent as a
        # brief and the change framing was dropped entirely
        prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
          brief: "",
          aspect: "16:9",
          kind: ImageGen::Kind::Edit,
          instruction: "swap the date to 12 September",
        ))
        prompt.should contain "The change to make now, and the only one: swap the date to 12 September"
      end

      it "lists changes already applied when refining" do
        prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
          brief: "a poster for the office party",
          aspect: "16:9",
          kind: ImageGen::Kind::Edit,
          history: ["make it warmer"],
          instruction: "add paper decorations",
        ))

        prompt.should contain "It was made for this brief: a poster for the office party"
        prompt.should contain "Change 1, already applied: make it warmer"
        prompt.should contain "The change to make now, and the only one: add paper decorations"
      end
    end

    it "numbers attached images from one, and says the edited image is not one of them" do
      generating = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
        brief: "a poster in the style of image 1 with the person from image 2",
        aspect: "16:9",
        references: 2,
      ))

      generating.should contain "2 image(s) are attached with this request, numbered 1 to 2"
      generating.should_not contain "The first attached image is the image being edited"

      editing = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
        brief: "a poster for the office party",
        aspect: "16:9",
        kind: ImageGen::Kind::Edit,
        instruction: "put the person from image 1 on the right",
        references: 1,
      ))

      editing.should contain "The first attached image is the image being edited."
      editing.should contain "The 1 image(s) after it were supplied with this request, numbered 1 to 1"
    end

    it "says nothing about attached images when none are attached" do
      prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
        brief: "a poster for the office party",
        aspect: "16:9",
      ))

      prompt.should_not contain "attached"
    end

    it "carries the brand kit, the brief and each change in order" do
      prompt = ImageGen::Prompt.build(ImageGen::Prompt::Options.new(
        brief: "a poster for the office party",
        aspect: "16:9",
        brand: brand,
        history: ["make it warmer"],
        instruction: "add decorations",
      ))

      prompt.should contain "Organisation: Acme."
      prompt.should contain "primary #0E6E52"
      prompt.should contain "Change 1: make it warmer"
      prompt.should contain "Change 2: add decorations"
      prompt.should contain "Keep everything else exactly as it is."
      prompt.should contain "Never include: competitor logos."
    end
  end
end
