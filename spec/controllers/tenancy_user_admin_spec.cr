require "../helper"

module PlaceOS::Api
  describe "selected user metadata and organisation administrator availability" do
    fixture = nil.as(Spec::Tenancy::Fixture?)
    before_each { Utils::Tenancy.enforce = true }
    after_each do
      Utils::Tenancy.enforce = false
      if f = fixture
        Spec::Tenancy.teardown(f)
        fixture = nil
      end
    end

    it "searches and counts the selected organisation rather than the login authority" do
      f = fixture = Spec::Tenancy.build
      marker = UUID.random.to_s
      [f.acadian.user, f.ucla.user].each do |user|
        Model::Generator.metadata(name: random_name, parent: user.id).tap(&.details = JSON.parse({marker: marker}.to_json)).save!
      end
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Read).save!
      query = HTTP::Params{"filter" => %($.marker ? (@ == "#{marker}")), "organisation_id" => f.acadian.organisation.id.to_s}
      response = client.get("#{Users.base_route}metadata/search?#{query}", headers: Spec::Tenancy.headers(f.ucla.admin))
      response.status_code.should eq 200
      Spec::Tenancy.ids(response.body).should eq [f.acadian.user.id]
      response.headers["X-Total-Count"].should eq "1"
      query.delete("organisation_id")
      home = client.get("#{Users.base_route}metadata/search?#{query}", headers: Spec::Tenancy.headers(f.ucla.admin))
      home.status_code.should eq 200
      Spec::Tenancy.ids(home.body).should eq [f.ucla.user.id]
      headers = Spec::Tenancy.headers(f.ucla.admin)
      token = Model::UserJWT.decode(headers["Authorization"].split(' ').last)
      limited = Model::UserJWT.new(iss: token.iss, iat: token.iat, exp: token.exp, domain: token.domain, id: token.id, user: token.user,
        scope: [Model::UserJWT::Scope.new("users", Model::UserJWT::Scope::Access::Write)])
      headers["Authorization"] = "Bearer #{limited.encode}"
      client.get("#{Users.base_route}metadata/search?#{query}", headers: headers).status_code.should eq 403
    end

    it "keeps authority read grants exact during metadata search" do
      f = fixture = Spec::Tenancy.build
      second = Model::Generator.authority("metadata-sibling.test").tap(&.organisation_id = f.acadian.organisation.id).save!
      sibling_user = Model::Generator.user(second).save!
      marker = UUID.random.to_s
      [f.acadian.user, sibling_user].each do |user|
        Model::Generator.metadata(name: random_name, parent: user.id).tap(&.details = JSON.parse({marker: marker}.to_json)).save!
      end
      Model::Generator.grant(f.ucla.admin, "authority", f.acadian.authority.id.as(String), Model::Permissions::Read).save!
      query = HTTP::Params{"filter" => %($.marker ? (@ == "#{marker}")), "organisation_id" => f.acadian.organisation.id.to_s}
      response = client.get("#{Users.base_route}metadata/search?#{query}", headers: Spec::Tenancy.headers(f.ucla.admin))
      response.status_code.should eq 200
      Spec::Tenancy.ids(response.body).should eq [f.acadian.user.id]
      response.headers["X-Total-Count"].should eq "1"
    end

    it "refuses soft deletion of the last active organisation administrator" do
      f = fixture = Spec::Tenancy.build
      f.acadian.authority.internals_will_change!
      f.acadian.authority.internals["soft_delete"] = JSON::Any.new(true)
      f.acadian.authority.save!
      response = client.delete("#{Users.base_route}#{f.acadian.admin.id}", headers: Spec::Tenancy.headers(f.acadian.admin))
      response.status_code.should eq 403
      Model::User.find!(f.acadian.admin.id.as(String)).deleted.should be_false
    end

    it "refuses demotion of the last active organisation administrator" do
      f = fixture = Spec::Tenancy.build
      response = client.patch("#{Users.base_route}#{f.acadian.admin.id}", headers: Spec::Tenancy.headers(f.acadian.admin), body: {sys_admin: false}.to_json)
      response.status_code.should eq 403
      Model::User.find!(f.acadian.admin.id.as(String)).sys_admin.should be_true
    end

    it "allows soft deletion and demotion when another active administrator remains" do
      f = fixture = Spec::Tenancy.build
      other = Model::Generator.user(f.acadian.authority, admin: true).save!
      headers = Spec::Tenancy.headers(f.acadian.admin)
      client.patch("#{Users.base_route}#{other.id}", headers: headers, body: {sys_admin: false}.to_json).status_code.should eq 200
      other.reload!
      other.sys_admin = true
      other.save!
      f.acadian.authority.internals_will_change!
      f.acadian.authority.internals["soft_delete"] = JSON::Any.new(true)
      f.acadian.authority.save!
      client.delete("#{Users.base_route}#{other.id}", headers: headers).status_code.should eq 202
      Model::User.find!(other.id.as(String)).deleted.should be_true
      client.patch("#{Users.base_route}#{f.acadian.admin.id}", headers: headers, body: {sys_admin: false}.to_json).status_code.should eq 403
    end

    it "serialises concurrent removals without relying on another organisation's admins" do
      f = fixture = Spec::Tenancy.build
      other = Model::Generator.user(f.acadian.authority, admin: true).save!
      Model::Generator.grant(f.ucla.admin, "organisation", f.acadian.organisation.id.to_s, Model::Permissions::Manage).save!
      headers = Spec::Tenancy.headers(f.ucla.admin)
      responses = Channel(Int32).new(2)
      start = Channel(Nil).new
      [f.acadian.admin, other].each do |target|
        spawn do
          start.receive
          result = ActionController::SpecHelper.client.delete("#{Users.base_route}#{target.id}?organisation_id=#{f.acadian.organisation.id}", headers: headers)
          responses.send(result.status_code)
        end
      end
      2.times { start.send(nil) }
      results = [] of Int32
      2.times do
        select
        when status = responses.receive then results << status
        when timeout(10.seconds) then fail "concurrent administrator deletion did not finish"
        end
      end
      results.sort.should eq [202, 403]
      Model::User.where(authority_id: f.acadian.authority.id, sys_admin: true, deleted: false).count.should eq 1
    end
  end
end
