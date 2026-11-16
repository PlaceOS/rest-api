require "../helper"

module PlaceOS::Api
  describe ChatGPT do
    before_each do
      Model::ChatMessage.clear
      Model::Chat.clear
    end

    Spec.test_404(ChatGPT.base_route, model_name: Model::Chat.table_name)

    it "GET should return an empty list of chats for users without any chat history" do
      resp = client.get("#{ChatGPT.base_route}",
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)

      JSON.parse(resp.body).size.should eq(0)
    end

    it "GET should return list of chats" do
      user = Spec::Authentication.user
      PlaceOS::Model::Generator.chat(user: user).save!

      resp = client.get("#{ChatGPT.base_route}",
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)

      JSON.parse(resp.body).size.should eq(1)
    end

    it "GET should return list of chat history" do
      user = Spec::Authentication.user
      chat = PlaceOS::Model::Generator.chat(user: user).save!
      PlaceOS::Model::Generator.chat_message(chat: chat).save!

      resp = client.get("#{ChatGPT.base_route}#{chat.id}",
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)
      hist = JSON.parse(resp.body).as_a
      hist.size.should eq(1)
      hist.first.as_h["role"].should eq("user")
    end

    it "GET should return list of chat history and filter out system messages" do
      user = Spec::Authentication.user
      chat = PlaceOS::Model::Generator.chat(user: user).save!
      PlaceOS::Model::Generator.chat_message(chat: chat).save!

      PlaceOS::Model::Generator.chat_message(chat: chat, role: PlaceOS::Model::ChatMessage::Role::Assistant).save!
      PlaceOS::Model::Generator.chat_message(chat: chat, role: PlaceOS::Model::ChatMessage::Role::System).save!
      PlaceOS::Model::Generator.chat_message(chat: chat, role: PlaceOS::Model::ChatMessage::Role::Function).save!

      resp = client.get("#{ChatGPT.base_route}#{chat.id}",
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(200)
      hist = JSON.parse(resp.body).as_a
      hist.size.should eq(2)
      hist.first.as_h["role"].should eq("user")
      hist.last.as_h["role"].should eq("assistant")
    end

    it "deleting chat should delete all associated history" do
      chat = PlaceOS::Model::Generator.chat(user: Spec::Authentication.user).save!
      PlaceOS::Model::Generator.chat_message(chat: chat).save!

      PlaceOS::Model::Generator.chat_message(chat: chat, role: PlaceOS::Model::ChatMessage::Role::Assistant).save!
      PlaceOS::Model::Generator.chat_message(chat: chat, role: PlaceOS::Model::ChatMessage::Role::System).save!

      PlaceOS::Model::ChatMessage.where(chat_id: chat.id).count.should eq(3)

      resp = client.delete("#{ChatGPT.base_route}#{chat.id}",
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(202)

      PlaceOS::Model::ChatMessage.where(chat_id: chat.id).count.should eq(0)
    end

    describe "other users' chats" do
      it "show returns 404 for a chat owned by someone else" do
        chat = PlaceOS::Model::Generator.chat.save!
        PlaceOS::Model::Generator.chat_message(chat: chat).save!

        {
          Spec::Authentication.headers,
          Spec::Authentication.authentication(sys_admin: false, support: false).last,
        }.each do |headers|
          resp = client.get("#{ChatGPT.base_route}#{chat.id}", headers: headers)
          resp.status_code.should eq(404)
          resp.body.should_not contain(PlaceOS::Model::ChatMessage.where(chat_id: chat.id).first.content.as(String))
        end
      end

      it "destroy returns 404 and keeps a chat owned by someone else" do
        chat = PlaceOS::Model::Generator.chat.save!
        PlaceOS::Model::Generator.chat_message(chat: chat).save!

        resp = client.delete("#{ChatGPT.base_route}#{chat.id}",
          headers: Spec::Authentication.authentication(sys_admin: false, support: false).last)
        resp.status_code.should eq(404)

        PlaceOS::Model::Chat.find?(chat.id).should_not be_nil
        PlaceOS::Model::ChatMessage.where(chat_id: chat.id).count.should eq(1)
      end

      it "websocket resume refuses a chat owned by someone else" do
        chat = PlaceOS::Model::Generator.chat.save!
        headers = Spec::Authentication.authentication(sys_admin: false, support: false).last

        expect_raises(Socket::Error, /404/) do
          client.establish_ws("#{ChatGPT.base_route}chat/#{chat.system_id}?resume=#{chat.id}", headers: headers)
        end
      end
    end
  end
end
