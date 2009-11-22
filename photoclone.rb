%w(rubygems sinatra digest/md5 rack-flash json restclient models hello haml rmagick).each  { |lib| require lib}
set :sessions, true
set :show_exceptions, false
use Rack::Flash
include Magick

get "/" do
  if session[:userid].nil? then 
    @token = "http://#{env["HTTP_HOST"]}/after_login"
    haml :login 
  else
    @user = User.get(session[:userid])
    @hello = HELLO[rand(HELLO.size)]
    haml :landing
  end
end

get "/logout" do
  session[:userid] = nil
  redirect "/"
end

# called by RPX after the login completes
post "/after_login" do
  profile = get_user_profile_with params[:token]
  user = User.find(profile["identifier"])
  if user.new_record?
    photo = profile ["email"] ? "http://www.gravatar.com/avatar/#{Digest::MD5.hexdigest(profile["email"])}" : profile["photo"] 
    unless user.update_attributes({:nickname => profile["identifier"].hash.to_s(36), :email => profile["email"], :photo_url => photo, :provider => profile["provider"]})
      flash[:error] = user.errors.values.join(",")
      redirect "/"
    end
    session[:userid] = user.id
    redirect "/change_profile"
  else
    session[:userid] = user.id
    redirect "/"    
  end
end

get "/profile" do
  load_users(session[:userid])
  haml :profile
end

get "/change_profile" do  haml :change_profile end

post "/save_profile" do
  user = User.get(session[:userid])
  unless user.update_attributes(:nickname => params[:nickname], :formatted_name => params[:formatted_name], :location => params[:location], :description => params[:description])
    flash[:error] = user.errors.values.join(",")
    redirect "/change_profile"
  end
  redirect "/"
end


# show all albums belonging to the user
get "/albums" do
  @myself = @user = User.get(session[:userid])
  haml :"albums/manage"
end

get "/albums/:user_id" do
  @myself = User.get(session[:userid])
  @user = User.get(params[:user_id])
  haml :"albums/manage"
end

# add album
get "/album/add" do
  haml :"/albums/add"
end

# create album
post "/album/create" do
  album = Album.new
  album.attributes = {:name => params[:name], :description => params[:description]}
  album.user = User.get(session[:userid])
  album.save
  redirect "/albums"
end

post "/album/cover/:photo_id" do
   photo = Photo.get(params[:photo_id])  
   album = photo.album
   album.cover_photo = photo   
   album.save!
   redirect "/album/#{album.id}"
end

# delete album
delete "/album/:id" do
  album = Album.get(params[:id])
  user = User.get(session[:userid])
  if album.user == user
    if album.destroy
      redirect "/albums"
    else
      throw "Cannot delete this album!"
    end
  else
    throw "This is not your album, you cannot delete it!"
  end
end

# show all photos in this album
get "/album/:id" do
  @album = Album.get params[:id]
  @user = User.get session[:userid]
  haml :"/albums/view"
end

# save an edited photo
post "/photo/save_edited/:original_photo_id" do
  if params[:original_photo_id] && params["image"] && (tmpfile = params["image"][:tempfile]) && (name = params["image"][:filename])
    original_photo = Photo.get params[:original_photo_id]
    new_photo = Photo.new(:title => name, :album => original_photo.album, :tmpfile => tmpfile)
    original_photo.versions << new_photo
    original_photo.save    
  end  
  redirect "/photo/#{original_photo.id}"
end

# edit photo properties
post "/photo/:property/:photo_id" do
  photo = Photo.get params[:photo_id]
  photo.send(params[:property] + '=', params[:value])
  photo.save
  photo.send(params[:property])
end

# edit album properties
post "/album/:property/:photo_id" do
  album = Album.get params[:photo_id]
  album.send(params[:property] + '=', params[:value])
  album.save
  album.send(params[:property])
end


# show this photo
get "/photo/:id" do
  @photo = Photo.get params[:id]
  @user = User.get session[:userid]
  halt 403, 'This is a private photo' if @photo.privacy == 'Private' and @user != @photo.album.user
  
	notes = @photo.annotations.collect do |n|
    '{"x1": "' + n.x.to_s + '", "y1": "' + n.y.to_s + 
    '", "height": "' + n.height.to_s + '", "width": "' + n.width.to_s + 
    '","note": "' + n.description + '"}'
  end
  @notes = notes.join(',')
  @prev_in_album = @photo.previous_in_album(@user)
  @next_in_album = @photo.next_in_album(@user)
  haml :photo
end


# upload photos
get "/upload" do
  @albums = User.get(session[:userid]).albums
  haml :upload
end

get "/album/:id/upload" do
  @albums = [Album.get(params[:id])]
  haml :upload  
end

post "/upload" do
  album = Album.get params[:album_id]
  (1..6).each do |i|
    if params["file#{i}"] && (tmpfile = params["file#{i}"][:tempfile]) && (name = params["file#{i}"][:filename])
      Photo.new(:title => name, :album => album, :tmpfile => tmpfile).save
    end
  end
  redirect "/album/#{album.id}"
end

# add annotation
post "/annotation/:photo_id" do
  photo = Photo.get params[:photo_id]
  note = Annotation.create(:x => params["annotation"]["x1"], 
                           :y => params["annotation"]["y1"], 
                           :height => params["annotation"]["height"],
                           :width => params["annotation"]["width"],
                           :description => params["annotation"]["text"])
  photo.annotations << note
  photo.save
  redirect "/photo/#{params[:photo_id]}"
end

# delete annotation
delete "/annotation/:id" do
  note = Annotation.get(params[:id])
  photo = note.photo
  if note.destroy
    redirect "/photo/#{photo.id}"
  else
      throw "Cannot delete this annotation!"
  end
end

# add comment
post "/comment/:photo_id" do
  photo = Photo.get params[:photo_id]
  comment = Comment.create(:text => params[:text])
  comment.user = User.get session[:userid]
  photo.comments << comment
  photo.save
  redirect "/photo/#{params[:photo_id]}"
end

# remove comment
delete "/comment/:id" do
  comment = Comment.get(params[:id])
  photo = comment.photo
  commentor = comment.user
  user = User.get session[:userid]
  comment.destroy if user == commentor
  redirect "/photo/#{photo.id}"
end

# manage list of people you follow
get "/follows" do
  @user = User.get session[:userid]
  @follows = @user.follows
  if params[:query]
    @search_results = User.all(:nickname.like => params[:query] + '%', :limit => 10)
  end
  haml :'follows/manage'
end  

# follow the user
put "/follow/:user_id" do
  me = User.get session[:userid]
  person = User.get params[:user_id]
  me.follow person
  redirect "/follows"
end

# unfollow the user
delete "/follow/:user_id" do
  me = User.get session[:userid]
  person = User.get params[:user_id]
  me.unfollow person
  redirect "/follows"  
end


# delete photo
delete "/photo/:id" do  
  photo = Photo.get(params[:id])
  album = photo.album
  photo.destroy
  redirect "/album/#{album.id}"
end

load "helpers.rb"