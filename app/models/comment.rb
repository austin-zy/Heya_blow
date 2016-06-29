class Comment < ActiveRecord::Base
  include ActsAsCommentable::Comment
  include Rakismet::Model
  rakismet_attrs :author => :author_name, :comment_type => 'comment', :content => :comment, :user_ip => :author_ip

  belongs_to :commentable, :polymorphic => true
  belongs_to :user, :inverse_of => :comments_as_author, :foreign_key => 'user_id', :class_name => "User"
  belongs_to :recipient, :class_name => "User", :foreign_key => "recipient_id"

  validates_presence_of :comment
  validates_presence_of :commentable_id, :commentable_type
  validates_length_of :comment, :maximum => 2000

  before_save :whitelist_attributes
  after_create :send_notifications
  after_save :send_notifications, :if => Proc.new{|record| record.role_change.eql?(['pending', 'published']) }

  validates_presence_of :user, :unless => Proc.new{|record| configatron.allow_anonymous_commenting }
  validates_presence_of :author_email, :unless => Proc.new{|record| record.user }  #require email unless logged in
  validates_presence_of :author_ip, :unless => Proc.new{|record| record.user} #log ip unless logged in
  validates_format_of :author_url, :with => /(^$)|(^(http|https):\/\/[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?$)/ix, :unless => Proc.new{|record| record.user }
  validate :check_spam

  acts_as_activity :user, :if => Proc.new{|record| record.user && !record.pending? } #don't record an activity if there's no user

  def self.find_photo_comments_for(user)
    Comment.where("recipient_id = ? AND commentable_type = ?", user.id, 'Photo').order('created_at DESC')
  end

  def previous_commenters_to_notify
    # only send a notification on recent comments
    # limit the number of emails we'll send (or posting will be slooowww)
    users = User.includes(:comments_as_author).limit(20)
    users = users.where(:notify_comments => true).where('users.id NOT IN (?)', [user_id, recipient_id.to_i])
    users = users.where(:comments => {
        :commentable_id => commentable_id,
        :commentable_type =>  commentable_type,
        :notify_by_email => true
        })
    users = users.where('comments.created_at > ?', 2.weeks.ago)
  end

  def commentable_name
    type = self.commentable_type.underscore
    case type
      when 'user'
        commentable.login
      when 'post'
        commentable.title
      when 'clipping'
        commentable.description || "Clipping from #{commentable.user.login}"
      when 'photo'
        commentable.description || "Photo from #{commentable.user.login}"
      else
        commentable.class.to_s.humanize
    end
  end

  def title_for_rss
    "Comment from #{username}"
  end

  def username
    user ? user.login : (author_name.blank? ? 'Anonymous' : author_name)
  end

  def self.find_recent(options = {:limit => 5})
    where("created_at > '#{14.days.ago.iso8601}'").order("created_at DESC").limit(options[:limit])
  end

  def can_be_deleted_by(person)
    person && (person.admin? || person.id.eql?(user_id) || person.id.eql?(recipient_id) )
  end

  def should_notify_recipient?
    return false unless recipient && recipient.email
    return false if recipient.eql?(user)
    return false unless recipient.notify_comments?
    true
  end

  def notify_previous_commenters
    previous_commenters_to_notify.each do |commenter|
      UserNotifier.follow_up_comment_notice(commenter, self).deliver_now if commenter.email
    end
  end

  def notify_previous_anonymous_commenters
    anonymous_commenters_emails = commentable.comments.map{|c|  c.author_email if (c.notify_by_email? && !c.user && !c.author_email.eql?(self.author_email) && c.author_email) }.uniq.compact
    anonymous_commenters_emails.each do |email|
      UserNotifier.follow_up_comment_notice_anonymous(email, self).deliver_now
    end
  end

  def send_notifications
    return if commentable.respond_to?(:send_comment_notifications?) && !commentable.send_comment_notifications?
    return if pending?
    UserNotifier.comment_notice(self).deliver_now if should_notify_recipient?
    self.notify_previous_commenters
    self.notify_previous_anonymous_commenters if configatron.allow_anonymous_commenting
  end

  def token_for(email)
    Digest::SHA1.hexdigest("#{id}--#{email}--#{created_at}")
  end

  def unsubscribe_notifications(email)
    commentable.comments.where(:author_email => email).each do |previous_comment|
      previous_comment.update_attribute :notify_by_email, false
    end
  end

  def check_spam
    if configatron.has_key?(:akismet_key) && self.spam?
      self.role = 'pending'
    end
  end

  def pending?
    role.eql?('pending')
  end


  protected
  def whitelist_attributes
    self.comment = Sanitize.clean(self.comment, WhiteListHelper.settings.merge({:add_attributes => {'a' => {'rel' => 'nofollow'}}}) )
    white_list(self.comment)
  end


end
