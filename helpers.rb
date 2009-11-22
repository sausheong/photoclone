helpers do
  def load_users(id)
    @myself = User.get(id)
    @user = @myself
  end

  def message_count
    Status.count(:recipient_id => session[:userid]) + Status.count(:user_id => session[:userid], :recipient_id.not => nil) || 0
  end

  def get_user_profile_with(token)
    response = RestClient.post 'https://rpxnow.com/api/v2/auth_info', 'token' => token, 'apiKey' => '6424ada6ed6e452230c66637329163d2f5a4b290', 'format' => 'json', 'extended' => 'true'
    json = JSON.parse(response)
    return json['profile'] if json['stat'] == 'ok'
    raise LoginFailedError, 'Cannot log in. Try another account!' 
  end


  def time_ago_in_words(timestamp)
    minutes = (((Time.now - timestamp).abs)/60).round
    return nil if minutes < 0

    case minutes
    when 0               then 'less than a minute ago'
    when 0..4            then 'less than 5 minutes ago'
    when 5..14           then 'less than 15 minutes ago'
    when 15..29          then 'less than 30 minutes ago'
    when 30..59          then 'more than 30 minutes ago'
    when 60..119         then 'more than 1 hour ago'
    when 120..239        then 'more than 2 hours ago'
    when 240..479        then 'more than 4 hours ago'
    else                 timestamp.strftime('%I:%M %p %d-%b-%Y')
    end
  end

  def protected!
    response['WWW-Authenticate'] = %(Basic realm="PhotoClone") and
    throw(:halt, [401, "Not authorized\n"]) and
    return unless authorized?
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials && check(@auth.credentials)
  end
  
  def check(credentials)
    email, password = *credentials
    return false unless User.first(:email => email)
    response = RestClient.post 'https://www.google.com/accounts/ClientLogin', 'accountType' => 'HOSTED_OR_GOOGLE', 'Email' => email, 'Passwd' => password, :service => 'xapi', :source => 'Goog-Auth-1.0'
    response.code == 200
  end
  
  def snippet(page, options={})
    haml page, options.merge!(:layout => false)
  end
  
end