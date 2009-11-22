DataMapper.auto_migrate!
puts 'Creating users'
$u = User.create(:nickname => 'Paul')
puts 'Creating friends'
$f1 = User.create(:nickname => 'Mary')
$f2 = User.create(:nickname => 'Peter')

$u.befriends($f1)

album = Album.create(:name => 'Japan trip')
$u.albums << album

photo = Photo.create(:title => 'pic1.jpg')
album.photos << photo

puts 'Done!'

