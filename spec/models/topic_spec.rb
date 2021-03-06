# frozen_string_literal: true

require "rails_helper"

describe Topic, type: :model do
  let(:topic) { create(:topic) }
  let(:user) { create(:user) }

  it "should no save invalid node_id" do
    expect(build(:topic, node_id: nil).valid?).not_to be_truthy
  end

  it "should set last_active_mark on created" do
    # because the Topic index is sort by replied_at,
    # so the new Topic need to set a Time, that it will display in index page
    expect(create(:topic).last_active_mark).not_to be_nil
  end

  it "should not update last_active_mark on save" do
    last_active_mark_was = topic.last_active_mark
    topic.save
    expect(topic.last_active_mark).to eq(last_active_mark_was)
  end

  it "should get node name" do
    node = create :node
    expect(create(:topic, node: node).node_name).to eq(node.name)
  end

  it "should update after reply" do
    reply = create :reply, topic: topic, user: user
    expect(topic.last_active_mark).not_to be_nil
    expect(topic.replied_at.to_i).to eq(reply.created_at.to_i)
    expect(topic.last_reply_id).to eq(reply.id)
    expect(topic.last_reply_user_id).to eq(reply.user_id)
    expect(topic.last_reply_user_login).to eq(reply.user.login)
  end

  it "should update after reply without last_active_mark when the topic is created at month ago" do
    allow(topic).to receive(:created_at).and_return(1.month.ago)
    allow(topic).to receive(:last_active_mark).and_return(1)
    reply = create :reply, topic: topic, user: user
    expect(topic.last_active_mark).not_to eq(reply.created_at.to_i)
    expect(topic.last_reply_user_id).to eq(reply.user_id)
    expect(topic.last_reply_user_login).to eq(reply.user.login)
  end

  it "should not update last_active_mark when update reply" do
    reply = create :reply, topic: topic, user: user
    old_last_active_mark = topic.last_active_mark
    reply.body = "foobar"
    reply.save
    expect(topic.last_active_mark).to eq(old_last_active_mark)
  end

  it "should get page and floor by reply" do
    replies = []
    5.times do
      replies << create(:reply, topic: topic, user: user)
    end
    expect(topic.floor_of_reply(replies[2])).to eq(3)
    expect(topic.floor_of_reply(replies[3])).to eq(4)
  end

  it "should log deleted user name when use destroy_by" do
    t = create(:topic)
    t.destroy_by(user)
    expect(t.who_deleted).to eq(user.login)
    expect(t.deleted_at).not_to eq(nil)
    t1 = create(:topic)
    expect(t1.destroy_by(nil)).to eq(false)
  end

  describe "#auto_space_with_en_zh" do
    it "should auto fix on save" do
      topic.title = "Gitlab怎么集成GitlabCI"
      topic.save
      topic.reload
      expect(topic.title).to eq("Gitlab 怎么集成 GitlabCI")
    end
  end

  describe "#excellent" do
    it "should suggest a topic as excellent" do
      topic.excellent!
      topic.save
      expect(Topic.excellent).to include(topic)
    end
  end

  describe ".update_last_reply" do
    it "should work" do
      t = create(:topic)
      old_updated_at = t.updated_at
      r = create(:reply, topic: t)
      expect(t.update_last_reply(r)).to be_truthy
      expect(t.replied_at).to eq r.created_at
      expect(t.last_reply_id).to eq r.id
      expect(t.last_reply_user_id).to eq r.user_id
      expect(t.last_reply_user_login).to eq r.user.login
      expect(t.last_active_mark).not_to be_nil
      expect(t.updated_at).not_to eq old_updated_at
    end

    it "should update with nil when have :force" do
      t = create(:topic)
      t.update_last_reply(nil, force: true)
      expect(t.replied_at).to be_nil
      expect(t.last_reply_id).to be_nil
      expect(t.last_reply_user_id).to be_nil
      expect(t.last_reply_user_login).to be_nil
      expect(t.last_active_mark).not_to be_nil
    end
  end

  describe ".update_deleted_last_reply" do
    let(:t) { create(:topic) }
    context "when have last Reply and param it that Reply" do
      it "last reply should going to previous Reply" do
        r0 = create(:reply, topic: t)
        create(:reply, action: "foo")
        r1 = create(:reply, topic: t)
        expect(t.last_reply_id).to eq r1.id
        expect(t).to receive(:update_last_reply).with(r0, force: true)
        t.update_deleted_last_reply(r1)
      end

      it "last reply will be nil" do
        r = create(:reply, topic: t)
        expect(t.update_deleted_last_reply(r)).to be_truthy
        t.reload
        expect(t.last_reply_id).to be_nil
        expect(t.last_reply_user_login).to be_nil
        expect(t.last_reply_user_id).to be_nil
      end
    end

    context "when param is nil" do
      it "should work" do
        expect(t.update_deleted_last_reply(nil)).to be_falsey
      end
    end

    context "when last reply is not equal param" do
      it "should do nothing" do
        r0 = create(:reply, topic: t)
        r1 = create(:reply, topic: t)
        expect(t.update_deleted_last_reply(r0)).to be_falsey
        expect(t.last_reply_id).to eq r1.id
      end
    end
  end

  describe "#notify_topic_created" do
    let(:followers) { create_list(:user, 3) }
    let(:topic) { create(:topic, user: user) }

    it "should work" do
      followers.each do |f|
        f.follow_user(user)
      end

      # touch topic to create
      expect(topic).to be_a(Topic)

      followers.each do |f|
        expect(f.notifications.unread.where(notify_type: "topic").count).to eq 1
      end
    end
  end

  describe "#notify_topic_node_changed" do
    let(:topic) { create(:topic, user: user) }
    let(:new_node) { create(:node) }

    describe "Call method" do
      it "should work" do
        Topic.notify_topic_node_changed(topic.id, new_node.id)
        last_notification = user.notifications.unread.where(notify_type: "node_changed").first
        expect(last_notification.target_type).to eq "Topic"
        expect(last_notification.target_id).to eq topic.id
        expect(last_notification.second_target_type).to eq "Node"
        expect(last_notification.second_target_id).to eq new_node.id
      end
    end

    describe "on save callback" do
      it "with admin_editing no node_id changed" do
        topic.admin_editing = true
        expect(Topic).not_to receive(:notify_topic_node_changed)
        topic.save
      end

      it "with admin_editing and node_id_changed" do
        topic.admin_editing = true
        topic.node_id = new_node.id
        expect(Topic).to receive(:notify_topic_node_changed).once
        topic.save
      end

      it "without admin_editing" do
        topic.admin_editing = false
        topic.node_id = new_node.id
        topic.save
        expect(Topic).not_to receive(:notify_topic_node_changed)
      end
    end
  end

  describe ".ban!" do
    let!(:t) { create(:topic, user: user) }

    it "should ban! and lock topic" do
      t.ban!
      t.reload
      expect(t.ban?).to eq true
    end

    it "should ban! with reason" do
      allow(User).to receive(:current).and_return(user)
      t.ban!(reason: "Block this topic")
      t.reload
      expect(t.ban?).to eq true
      r = t.replies.last
      expect(r.action).to eq "ban"
      expect(r.body).to eq "Block this topic"
    end
  end

  describe ".reply_ids" do
    let(:t) { create(:topic) }
    let!(:replies) { create_list(:reply, 10, topic: t) }

    it "should work" do
      expect(t.reply_ids).to eq replies.collect(&:id)
    end
  end

  describe ".close! / .open! / closed?" do
    let!(:t) { create(:topic, user: user) }

    it "should work" do
      t.close!
      expect(t.closed?).to eq true
      t.open!
      expect(t.closed_at).to eq nil
      expect(t.closed?).to eq false
      t.close!
    end
  end

  describe ".excellent! / .unexcellent!" do
    let!(:t) { create(:topic, user: user) }

    it "should work" do
      allow(User).to receive(:current).and_return(user)
      expect do
        t.excellent!
      end.to change(Reply.where(action: "excellent", user: user), :count).by(1)
      expect(t.excellent?).to eq true
      expect do
        t.unexcellent!
      end.to change(Reply.where(action: "unexcellent", user: user), :count).by(1)
      expect(t.excellent?).to eq false
    end
  end

  describe "Search methods" do
    let(:t) { create :topic }

    before(:each) do
      t.reload
    end

    describe ".indexed_changed?" do
      it "title changed work" do
        expect(t.indexed_changed?).to eq false
        t.update(title: t.title + "1")
        expect(t.indexed_changed?).to eq true
      end

      it "body changed work" do
        expect(t.indexed_changed?).to eq false
        t.update(body: t.body + "1")
        expect(t.indexed_changed?).to eq true
      end

      it "other changed work" do
        expect(t.indexed_changed?).to eq false
        t.node_id = 3
        t.last_reply_id = 3
        t.who_deleted = "122"
        t.last_active_mark = Time.now.to_i
        t.suggested_at = Time.now
        t.save
        expect(t.indexed_changed?).to eq false
      end
    end
  end

  describe "RateLimit" do
    it "should limit by minute" do
      allow(Setting).to receive(:topic_create_limit_interval).and_return(60)
      user_id = 11
      t = build(:topic, user_id: user_id)
      assert_equal true, t.save
      assert_equal false, t.new_record?
      assert_equal 1, Rails.cache.read("users:#{user_id}:topic-create")
      assert_equal 1, Rails.cache.read("users:#{user_id}:topic-create-by-hour")

      t = build(:topic, user_id: user_id)
      assert_equal false, t.save
      assert_equal 1, t.errors.count
      assert_equal ["创建太频繁，请稍后再试"], t.errors&.messages.dig(:base)

      Rails.cache.delete("users:#{user_id}:topic-create")
      allow(Setting).to receive(:topic_create_limit_interval).and_return(0)
      t = build(:topic, user_id: user_id)
      t.save!
      assert_nil Rails.cache.read("users:#{user_id}:topic-create")
    end

    it "should limit by hour" do
      user_id = 12

      create(:topic, user_id: user_id)
      count = Rails.cache.read("users:#{user_id}:topic-create-by-hour")
      assert_equal 1, count

      create(:topic, user_id: user_id)
      count = Rails.cache.read("users:#{user_id}:topic-create-by-hour")
      assert_equal 2, count

      allow(Setting).to receive(:topic_create_hour_limit_count).and_return(10)
      Rails.cache.write("users:#{user_id}:topic-create-by-hour", 10)
      t = build(:topic, user_id: user_id)
      assert_equal false, t.save
      assert_equal ["1 小时内创建话题量不允许超过 10 篇，无法再次发布"], t.errors&.messages.dig(:base)

      allow(Setting).to receive(:topic_create_hour_limit_count).and_return(0)
      t = build(:topic, user_id: user_id)
      t.save!
    end
  end

  describe "Ban word in topic" do
    it "should work" do
      allow(Setting).to receive(:ban_words_in_body).and_return(["FFF", "AAAA"])
      t = build(:topic, body: "This is CCC")
      assert_equal true, t.valid?
      t = build(:topic, body: "This is FFFF")
      assert_equal false, t.valid?
      assert_equal ["敏感词 “FFF” 禁止发布！"],  t.errors&.messages.dig(:body)
      t = build(:topic, body: "This is AAAA")
      assert_equal false, t.valid?
      assert_equal ["敏感词 “AAAA” 禁止发布！"],  t.errors&.messages.dig(:body)
    end
  end
end
