require 'rubygems'
require_relative 'riakinterface'
require 'sinatra'
require 'sinatra/partial'
require 'haml'
require 'yaml'

use Rack::Logger
enable :logging, :dump_errors, :raise_errors
set :partial_template_engine, :haml
enable :sessions

helpers do

  def logger 
    request.logger
  end

  def userid_attr userid
    {:"data-userid" => userid}
  end

  def profileButtonTxt(bclass)
    case bclass 
      when "is-self" 
        "Self" 
      when "is-not-following" 
        "Not following" 
      when "is-following" 
        "Following" 
      else 
        "???" 
      end
  end

  def protected!
    return if authorized?
    headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
    halt 401, "Not authorized\n"
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    session['userid'] || (@auth.provided? and @auth.basic? and @auth.credentials and RiakClientInstance.new(settings.dbconfig).validateCredentials(@auth.credentials[0], @auth.credentials[1]))
  end
end

configure do
  set :dbconfig, YAML::load(File.open('./dbconfig.yaml'))
end


get '/auth/login' do
  haml :login, :layout => false
end

post '/auth/unauthenticated' do
  redirect '/auth/login'
end

get '/auth/logout' do
  logger.info("Logging out user #{session['userid']}.")
  session.clear
  redirect '/auth/login'
end

post '/auth/login' do
    u = BleaterAuth.validateCredentials(params["user"]["email"],params["user"]["password"])
    if(u)
    logger.info("User #{u['uid']} successfully authenticated. Redirection to home timeline.")
      
        session['userid'] = u['uid']
        redirect '/'
    else
    logger.info("Failed to authenticate user #{params["user"]["email"]}. Redirecting to login page")
      
        redirect '/auth/login'
    end
end

get '/api/timeline/:userid' do
    protected!
    logger.info("Getting timeline of user #{params[:userid]}.")
    RiakClientInstance.new(settings.dbconfig).retrieveTimeline params[:userid]
end

get '/api/bleats/:userid' do
   logger.info("Getting bleats of user #{params[:userid]}.")
  
   results = RiakClientInstance.new(settings.dbconfig).retrieveBleats params[:userid]
   logger.info("Results: #{results.inspect}")
   results
end

post '/api/bleat' do
 # protected!
   logger.info("Posting bleat from #{session['userid']}:\n#{params['content']}")
  RiakClientInstance.new(settings.dbconfig).postBleat(session['userid'], params['content'])
end

get '/api/profile/:userid' do
  RiakClientInstance.new(settings.dbconfig).getProfile(params["userid"])
end

post '/api/follow' do
  protected!
  logger.info("User #{session['userid']} following #{params["followee"]}")
  RiakClientInstance.new(settings.dbconfig).followUser(session['userid'], params["followee"])
end

post '/api/unfollow' do
  protected!
  logger.info("User #{session['userid']} unfollowing #{params["unfollowee"]}")
  RiakClientInstance.new(settings.dbconfig).unfollowUser(session['userid'], params["unfollowee"])
end

#DON'T DO THIS
post '/api/newuser' do
  uinfo = {
    "name" => request["name"],
    "handle" => request["handle"],
    "email" => request["email"],
    "password" => request["password"]
  }
  RiakClientInstance.new(settings.dbconfig).createUser uinfo
end


get '/' do
    client = RiakClientInstance.new(settings.dbconfig)
    if(!session['userid'])
      redirect '/auth/login'
    else
    myprofile = client.fetchProfile(session['userid'], session['userid'])
    mytimeline = client.retrieveTimeline session['userid']
    haml :main, :format => :html5, :locals => {:profileinfo => myprofile,
                                :bleats => mytimeline}
    end
  end

get '/user/:userid' do
    client = RiakClientInstance.new(settings.dbconfig) 
    if(!client.userExists?(params[:userid]))
    	return "User not found" 
    end
    userprofile = client.fetchProfile(params[:userid], session['userid'])
      usertimeline = client.retrieveBleats params[:userid]
  haml :main, :format => :html5, :locals => {:profileinfo => userprofile,
                              :bleats => usertimeline}
end
