require "../helper"

module PlaceOS::Api
  describe ChatGPT do
    ::Spec.before_each do
      Model::ChatMessage.clear
      Model::Chat.clear
    end

    Spec.test_404(ChatGPT.base_route, model_name: Model::Chat.table_name, headers: Spec::Authentication.headers)

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
      chat = PlaceOS::Model::Generator.chat.save!
      PlaceOS::Model::Generator.chat_message(chat: chat).save!

      PlaceOS::Model::Generator.chat_message(chat: chat, role: PlaceOS::Model::ChatMessage::Role::Assistant).save!
      PlaceOS::Model::Generator.chat_message(chat: chat, role: PlaceOS::Model::ChatMessage::Role::System).save!

      PlaceOS::Model::ChatMessage.where(chat_id: chat.id).count.should eq(3)

      resp = client.delete("#{ChatGPT.base_route}#{chat.id}",
        headers: Spec::Authentication.headers)

      resp.status_code.should eq(202)

      PlaceOS::Model::ChatMessage.where(chat_id: chat.id).count.should eq(0)
    end
  end
end
