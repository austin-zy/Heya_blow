class Topic < ActiveRecord::Base
  acts_as_activity :user

  acts_as_taggable
  belongs_to :forum, :counter_cache => true
  belongs_to :user
  has_many :monitorships
  has_many :monitors, -> { where('monitorships.active = ?', true) }, :through => :monitorships, :source => :user

  has_many :sb_posts, :dependent => :destroy, :inverse_of => :topic

  belongs_to :replied_by_user, :foreign_key => "replied_by", :class_name => "User"

  validates_presence_of :forum, :user, :title
  before_create :set_default_replied_at_and_sticky
  after_save    :set_post_topic_id
  after_create  :create_monitorship_for_owner

  accepts_nested_attributes_for :sb_posts

  scope :recently_replied, -> {order('replied_at DESC')}

  def notify_of_new_post(post)
    monitorships.each do |m|
      UserNotifier.new_forum_post_notice(m.user, post).deliver_now if (m.user != post.user) && m.user.notify_comments
    end
  end

  def to_param
    id.to_s << "-" << (title ? title.parameterize : '' )
  end

  def voices
    sb_posts.map { |p| p.user_id }.uniq.size
  end

  def body
    sb_posts.first
  end

  def hit!
    self.class.increment_counter :hits, id
  end

  def sticky?() sticky == 1 end

  def views() hits end

  def paged?() sb_posts_count > 25 end

  def last_page
    (sb_posts_count.to_f / 25.0).ceil.to_i
  end

  def editable_by?(user)
    user && (user.id == user_id || user.admin? || user.moderator_of?(forum_id))
  end

  protected
    def set_default_replied_at_and_sticky
      self.replied_at = Time.now.utc
      self.sticky   ||= 0
    end

    def set_post_topic_id
      SbPost.where('topic_id = ?', id).update_all(['forum_id = ?', forum_id])
    end

    def create_monitorship_for_owner
      monitorship = Monitorship.find_or_initialize_by(:user_id => user.id, :topic_id => self.id)
      monitorship.update_attribute :active, true
    end
end
