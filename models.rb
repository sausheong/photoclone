%w(dm-core dm-timestamps dm-validations RMagick right_aws config).each  { |lib| require lib}
include Magick
DataMapper.setup(:default, ENV['DATABASE_URL'] || 'mysql://root:root@localhost/photoclone')
S3 = RightAws::S3Interface.new(S3_CONFIG['AWS_ACCESS_KEY'], S3_CONFIG['AWS_SECRET_KEY'], {:multi_thread => true, :protocol => 'http', :port => 80} )

class User
  include DataMapper::Resource

  property :id,         Serial
  property :email,      String, :length => 255
  property :nickname,   String, :length => 255
  property :formatted_name, String, :length => 255
  property :provider,   String, :length => 255
  property :identifier, String, :length => 255
  property :photo_url,  String, :length => 255
  property :location, String, :length => 255
  property :description, String, :length => 255

  has n, :relationships
  has n, :followers, :through => :relationships, :class_name => "User", :child_key => [:user_id]
  has n, :follows, :through => :relationships, :class_name => "User", :remote_name => :user, :child_key => [:follower_id]
 
  has n, :albums
  has n, :photos, :through => :albums
  has n, :comments
  
  validates_is_unique :nickname, :message => "Someone else has taken up this nickname, try something else!"
  after :create, :create_s3_bucket
  
  def self.find(identifier)
    u = first(:identifier => identifier)
    u = new(:identifier => identifier) if u.nil?
    return u
  end    

  def follow(user)
    Relationship.create(:user => user, :follower => self)
  end

  def unfollow(user)
    Relationship.first(:user_id => user.id, :follower_id => self.id).destroy
  end

  def create_s3_bucket
    S3.create_bucket("pc.#{id}")
  end

end

class Relationship
  include DataMapper::Resource

  property :user_id, Integer, :key => true
  property :follower_id, Integer, :key => true
  belongs_to :user, :child_key => [:user_id]
  belongs_to :follower, :class_name => "User", :child_key => [:follower_id]
end

class Album
  include DataMapper::Resource
  property :id,         Serial
  property :name,       String, :length => 255
  property :description, Text
  property :created_at, DateTime
  
  belongs_to :user
  has n, :photos
  belongs_to :cover_photo, :class_name => 'Photo', :child_key => [:cover_photo_id]
  
  def original_photos(viewer)
    criteria = {:original_photo_id => nil, :order => [:created_at.desc]}
    criteria[:privacy] = 'public' if viewer != user
    photos(criteria)
  end

  def edited_photos(viewer)
    criteria = {:original_photo_id.not => nil, :order => [:created_at.desc]}
    criteria[:privacy] = 'public' if viewer != user
    photos(criteria)
  end

  def public_photos
     photos(:original_photo_id => nil, :order => [:created_at.desc], :privacy => 'public')
  end

  def private_photos
     photos(:original_photo_id => nil, :order => [:created_at.desc], :privacy => 'private')
  end
  
end

class Photo
  include DataMapper::Resource
  attr_writer :tmpfile
  property :id,         Serial
  property :title,      String, :length => 255
  property :caption,    String, :length => 255
  property :privacy,    String, :default => 'public'
  
  property :format,     String
  property :created_at, DateTime
  
  belongs_to :album
  belongs_to :original, :class_name => 'Photo', :child_key => [:original_photo_id]
  
  has n, :annotations
  has n, :comments
  has n, :versions, :class_name => 'Photo'
  
  after :save, :save_image_s3
  after :destroy, :destroy_image_s3
  
  def public?
    privacy == 'public'
  end

  def private?
    privacy == 'private'
  end
  
  def filename_original
    "#{id}.orig"
  end
  
  def filename_display
    "#{id}.disp"
  end
    
  def filename_thumbnail
    "#{id}.thmb"
  end
  
  def url_thumbnail
    S3.get_link(s3_bucket, filename_thumbnail)
  end

  def url_display
    create_tmp_from_s3
    "/photos/#{id}.tmp"
  end  
  
  def previous_in_album(viewer)    
    photos = viewer == album.user ? album.original_photos(viewer) : album.public_photos       
    index = photos.index self
    if index > 0
      photos[index - 1] 
     else
      photos[index] 
     end
  end

  def next_in_album(viewer)
    photos = viewer == album.user ? album.original_photos(viewer) : album.public_photos
    index = photos.index self
    if index < album.photos.length 
      photos[index + 1] 
    else
      photos[index]
    end
  end              

  
  def save_image_file
    return unless @tmpfile
    saved_file = File.dirname(__FILE__) + '/public/photos/' + filename_original

    File.open(saved_file,"w") do |f|
      while block = @tmpfile.read(65536)
        f.write block
      end
    end

    # generate the display image, used to display photo page
    img = Magick::Image.read(saved_file).first
    display = img.resize_to_fit(500)
    display.write(File.dirname(__FILE__) + '/public/photos/' + filename_display)

    # generate the thumbnail image
    t = img.resize_to_fit(150)
    length = t.rows > t.columns ? t.columns : t.rows
    thumbnail =  t.crop(CenterGravity, length, length)
    thumbnail.write(File.dirname(__FILE__) + '/public/photos/' + filename_thumbnail)    

  end

  def save_image_s3
    return unless @tmpfile
    S3.put(s3_bucket, filename_original, @tmpfile)

    img = Magick::Image.read(@tmpfile.open).first
    display = img.resize_to_fit(500)  
    S3.put(s3_bucket, filename_display, display.to_blob)  

    t = img.resize_to_fit(150)
    length = t.rows > t.columns ? t.columns : t.rows
    thumbnail =  t.crop(CenterGravity, length, length)
    S3.put(s3_bucket, filename_thumbnail, thumbnail.to_blob)  
  end
  
  def destroy_image_s3
    S3.delete s3_bucket, filename_original
    S3.delete s3_bucket, filename_display
    S3.delete s3_bucket, filename_thumbnail
  end
  
  def create_tmp_from_s3
    display_tmp = File.dirname(__FILE__) + "/public/photos/#{id}.tmp"
    return if File.exists? display_tmp
    File.open(display_tmp, 'w+') do |file|
      S3.get(s3_bucket, filename_display) do |chunk|
        file.write chunk
      end
    end
  end
  
  def s3_bucket
    "pc.#{album.user.id}"
  end           
  
  def self.random
    num_public_photos = all(:privacy => 'public').count
    return if num_public_photos == 0            
    all(:privacy => 'public')[rand(num_public_photos)].url_display    
  end
  
end


class Annotation
  include DataMapper::Resource
  property :id,         Serial
  property :description,Text
  property :x,          Integer
  property :y,          Integer
  property :height,     Integer
  property :width,      Integer
  property :created_at, DateTime
  
  belongs_to :photo
end

class Comment
  include DataMapper::Resource
  property :id,         Serial
  property :text,       Text
  property :created_at, DateTime
  
  belongs_to :user
  belongs_to :photo  
  
end