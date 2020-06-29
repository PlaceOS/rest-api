require "./helper"

module PlaceOS::Api
  describe ZoneMetadata do
    base = ZoneMetadata::NAMESPACE[0]
    _, authorization_header = authentication

    with_server do
      describe "/zones/:id/children/metadata" do
        it "shows zone children metadata" do
          parent = Model::Generator.zone.save!
          parent_id = parent.id.as(String)

          3.times do
            child = Model::Generator.zone
            child.parent_id = parent_id
            child.save!
            meta = Model::Zone::Metadata.new(name: Faker::Hacker.noun)
            meta.zone_id = child.id
            meta.save!
          end

          result = curl(
            method: "GET",
            path: "#{base}/children/metadata".gsub(":id", parent_id),
            headers: authorization_header,
          )

          metadata = Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, ZoneMetadata::Metadata))).from_json(result.body)
          metadata.size.should eq 3

          metadata.compact_map do |m|
            m[:metadata] unless m[:metadata].empty?
          end.size.should eq 3

          parent.destroy
        end

        it "filters zone children metadata" do
          parent = Model::Generator.zone.save!
          parent_id = parent.id.as(String)

          children = Array.new(size: 3) do
            child = Model::Generator.zone
            child.parent_id = parent_id
            child.save!
            meta = Model::Zone::Metadata.new(name: Faker::Hacker.noun)
            meta.zone_id = child.id
            meta.save!
            child
          end

          meta = Model::Zone::Metadata.new(name: "special")
          meta.zone_id = children.first.id
          meta.save!

          result = curl(
            method: "GET",
            path: "#{base}/children/metadata?name=special".gsub(":id", parent_id),
            headers: authorization_header,
          )

          metadata = Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, ZoneMetadata::Metadata))).from_json(result.body)

          metadata.compact_map do |m|
            m[:metadata] unless m[:metadata].empty?
          end.size.should eq 1

          parent.destroy
        end
      end

      describe "/zones/:id/metadata" do
        it "shows zone metadata" do
          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)
          meta = Model::Zone::Metadata.new(name: "special")
          meta.zone_id = zone.id
          meta.save!

          result = curl(
            method: "GET",
            path: "#{base}/metadata".gsub(":id", zone_id),
            headers: authorization_header,
          )

          metadata = Hash(String, ZoneMetadata::Metadata).from_json(result.body)
          metadata.size.should eq 1
          metadata.first[1][:zone_id].should eq zone_id
        end

        it "filters zone metadata" do
          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)

          meta0 = Model::Zone::Metadata.new(name: Faker::Hacker.noun)
          meta0.zone_id = zone.id
          meta0.save!
          meta1 = Model::Zone::Metadata.new(name: "special")
          meta1.zone_id = zone.id
          meta1.save!

          result = curl(
            method: "GET",
            path: "#{base}/metadata?name=special".gsub(":id", zone_id),
            headers: authorization_header,
          )

          metadata = Hash(String, ZoneMetadata::Metadata).from_json(result.body)
          metadata.size.should eq 1
        end
      end
    end
  end
end
