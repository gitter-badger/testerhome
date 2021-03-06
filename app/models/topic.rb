# coding: utf-8
require "auto-space"

CORRECT_CHARS = [
  ['【', '['],
  ['】', ']'],
  ['（', '('],
  ['）', ')']
]

class Topic
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::BaseModel
  include Mongoid::SoftDelete
  include Mongoid::CounterCache
  include Mongoid::Likeable
  include Mongoid::MarkdownBody
  include Redis::Objects
  include Mongoid::Mentionable

  # 加入 Elasticsearch
  include Mongoid::Searchable

  mapping do
    indexes :title
    indexes :body
    indexes :node_name
  end

  def as_indexed_json(options={})
    {
        title: self.title,
        body: self.full_body,
        node_name: self.node_name,
        updated_at: self.updated_at,
        excellent: self.excellent,
        type_order: self.type_order
    }
  end

  field :title
  field :body
  field :body_html
  field :last_reply_id, type: Integer
  field :replied_at , type: DateTime
  field :source
  field :message_id
  field :replies_count, type: Integer, default: 0
  # 回复过的人的 ids 列表
  field :follower_ids, type: Array, default: []
  field :suggested_at, type: DateTime
  # 最后回复人的用户名 - cache 字段用于减少列表也的查询
  field :last_reply_user_login
  # 节点名称 - cache 字段用于减少列表也的查询
  field :node_name
  # 删除人
  field :who_deleted
  # 用于排序的标记
  field :last_active_mark, type: Integer
  # 是否锁定节点
  field :lock_node, type: Mongoid::Boolean, default: false
  # 精华帖 0 否， 1 是
  field :excellent, type: Integer, default: 0
  # 结贴 0 否， 1 是
  field :knot, type: Integer, default: 0


  # 保留所有权利，禁止转载.默认允许转载
  field :cannot_be_shared, type: Mongoid::Boolean, default: false

  # 修改了帖子的管理员
  belongs_to :modified_admin, class_name: 'User'

  # 临时存储检测用户是否读过的结果
  attr_accessor :read_state, :admin_editing, :admin_deleting

  belongs_to :user, inverse_of: :topics
  counter_cache name: :user, inverse_of: :topics
  belongs_to :node
  counter_cache name: :node, inverse_of: :topics
  belongs_to :last_reply_user, class_name: 'User'
  belongs_to :last_reply, class_name: 'Reply'
  has_many :replies, dependent: :destroy

  has_one :poll, dependent: :destroy

  validates_presence_of :user_id, :title, :body, :node

  index node_id: 1
  index user_id: 1
  index last_active_mark: -1
  index likes_count: 1
  index suggested_at: 1
  index excellent: -1

  counter :hits, default: 0

  delegate :login, to: :user, prefix: true, allow_nil: true
  delegate :body, to: :last_reply, prefix: true, allow_nil: true

  # scopes
  scope :last_actived, -> {  desc(:last_active_mark) }
  # 推荐的话题
  scope :suggest, -> { where(:suggested_at.ne => nil).desc(:suggested_at) }
  scope :fields_for_list, -> { without(:body,:body_html) }
  scope :high_likes, -> { desc(:likes_count, :_id) }
  scope :high_replies, -> { desc(:replies_count, :_id) }
  scope :no_reply, -> { where(replies_count: 0) }
  scope :popular, -> { where(:likes_count.gt => 5) }
  scope :without_node_ids, Proc.new { |ids| where(:node_id.nin => ids) }
  scope :excellent, -> { where(:excellent.gte => 1) }

  scope :without_hide_nodes, -> { where(:node_id.nin => Topic.topic_index_hide_node_ids) }
  scope :without_nodes, Proc.new { |node_ids|
                        ids = node_ids + self.topic_index_hide_node_ids
                        ids.uniq!
                        where(:node_id.nin => ids)
                      }
  scope :without_users, Proc.new { |user_ids| where(:user_id.nin => user_ids) }


  def self.find_by_message_id(message_id)
    where(message_id: message_id).first
  end

  # 排除隐藏的节点
  def self.without_hide_nodes
    where(:node_id.nin => self.topic_index_hide_node_ids)
  end

  def self.without_nodes(node_ids)
    where(:node_id.nin => node_ids)
  end

  def self.without_users(user_ids)
    where(:user_id.nin => user_ids)
  end

  def self.topic_index_hide_node_ids
    SiteConfig.node_ids_hide_in_topics_index.to_s.split(",").collect { |id| id.to_i }
  end

  before_save :store_cache_fields
  def store_cache_fields
    self.node_name = self.node.try(:name) || ""
  end
  before_save :auto_space_with_title
  def auto_space_with_title
    self.title.auto_space!
  end

  before_save :auto_correct_title
  def auto_correct_title
    CORRECT_CHARS.each do |chars|
      self.title.gsub!(chars[0], chars[1])
    end
    self.title.auto_space!
  end

  before_save do
    if self.admin_editing == true && self.node_id_changed?
      self.class.notify_topic_node_changed(self.id, self.node_id)
    end
  end

  before_destroy do
    if self.admin_deleting == true
      self.class.notify_topic_deleted(self.id)
    end
  end

  before_create :init_last_active_mark_on_create
  def init_last_active_mark_on_create
    self.last_active_mark = Time.now.to_i
  end

  after_create do
    NotifyTopicJob.perform_later(id)
  end

  def followed?(uid)
    follower_ids.include?(uid)
  end

  def push_follower(uid)
    return false if uid == user_id
    return false if followed?(uid)
    push(follower_ids: uid)
    true
  end

  def pull_follower(uid)
    return false if uid == user_id
    pull(follower_ids: uid)
    true
  end

  def update_last_reply(reply, opts = {})
    # replied_at 用于最新回复的排序，如果帖着创建时间在一个月以前，就不再往前面顶了
    return false if reply.blank? && !opts[:force]

    self.last_active_mark = Time.now.to_i if self.created_at > 3.months.ago
    self.replied_at = reply.try(:created_at)
    self.last_reply_id = reply.try(:id)
    self.last_reply_user_id = reply.try(:user_id)
    self.last_reply_user_login = reply.try(:user_login)
    self.__elasticsearch__.update_document
    self.save
  end

  # 更新最后更新人，当最后个回帖删除的时候
  def update_deleted_last_reply(deleted_reply)
    return false if deleted_reply.blank?
    return false if self.last_reply_user_id != deleted_reply.user_id

    previous_reply = self.replies.where(:_id.nin => [deleted_reply.id]).recent.first
    self.update_last_reply(previous_reply, force: true)
  end

  # 删除并记录删除人
  def destroy_by(user)
    return false if user.blank?
    self.update_attribute(:who_deleted,user.login)
    self.destroy
  end

  def destroy
    super
    delete_notifiaction_mentions
  end


  # 所有的回复编号
  def reply_ids
    Rails.cache.fetch([self,"reply_ids"]) do
      # self.replies.only(:_id).map(&:_id)
      replies.only(:_id).map(&:_id).sort
    end
  end

  def floor_of_reply(reply)
    reply_index = reply_ids.index(reply.id)
    reply_index + 1
  end

  def excellent?
    self.excellent >= 1
  end

  def knot?
    self.knot >= 1
  end

  def self.notify_topic_created(topic_id)
    topic = Topic.find_by_id(topic_id)
    return if topic.blank?

    notified_user_ids = topic.mentioned_user_ids

    follower_ids = (topic.user.try(:follower_ids) || [])
    follower_ids.uniq!

    # 给关注者发通知
    follower_ids.each do |uid|
      # 排除同一个回复过程中已经提醒过的人
      next if notified_user_ids.include?(uid)
      # 排除回帖人
      next if uid == topic.user_id
      puts "Post Notification to: #{uid}"
      Notification::Topic.create user_id: uid, topic_id: topic.id
    end
    true
  end

  def self.notify_topic_node_changed(topic_id, node_id)
    topic = Topic.find_by_id(topic_id)
    return if topic.blank?
    node = Node.find_by_id(node_id)
    return if node.blank?
    Notification::NodeChanged.create user_id: topic.user_id, topic_id: topic_id, node_id: node_id
    return true
  end

  def self.notify_topic_deleted(topic_id)
    topic = Topic.find_by_id(topic_id)
    return if topic.blank?
    Notification::TopicDeleted.create user_id: topic.user_id, topic_id: topic_id
    return true
  end

  def full_body
    ([self.body] + self.replies.pluck(:body)).join('\n\n')
  end

  def type_order
    1
  end

  def topic_pay_url
    self.user.qrcode_url
  end
end
