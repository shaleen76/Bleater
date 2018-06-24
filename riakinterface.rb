#Class representing an instance of a connection to the database.
require 'rubygems'
require 'bcrypt'
require 'riak'

class RiakClientInstance

#Constant determining how much we increment the counter whenever we create a new user.
@@new_id_range = 100
  #Initialize this class by creating a connection to our database.
  #This uses the Protocol Buffers API.
  def initialize(dbconf)
    @client = Riak::Client.new(host: dbconf['host'], pb_port: dbconf['port'])
  end 

  #Given a user id, get the bleats from all users they follow.
  def retrieveTimeline(userid)
  #M/R function, stored as a string literal, to get the user information of each followed user.
  retrieveUserInfo = <<JSFN1
  function(userinforval, keydata, args){
    var userinfo = Riak.mapValues(userinforval)[0];
    var userid = userinforval.key;
    return[['timelines', userid, {'uid' : userid, 'userinfo' : userinfo}]];
  }
JSFN1

#M/R map phase that unpacks the timeline object in the database.
  unpackTimeline = <<JSFN2
  function(timelinerval, userinfo, args){
    var timeline = Riak.mapValuesJson(timelinerval)[0]['bleat_ids'];
    return timeline.map(function(bleatid){
      return ['bleats', bleatid, userinfo]
    })
 }
JSFN2

#M/R map phase to merge the tweet and the information about the author.
  attachBleatInfo = <<JSFN3
  function(bleatrval, userinfo, args){
    var bleat = Riak.mapValuesJson(bleatrval)[0];
    return [{
      'tid' : bleatrval.key,
      'timestamp' : bleat.timestamp,
      'content' : bleat.content,
      'userinfo' : userinfo
    }];
  }
JSFN3

#Helper function passed to reduce phase to sort by descending order of timestamp.
  sortDescTimestamp = <<JSFN4
  function(t1, t2)
  {
    return t2.timestamp - t1.timestamp;
  }
JSFN4

    begin
      #Begin the query by using the secondary index to find all users that follow this one, then pipeline the results through each phase.
      results = Riak::MapReduce.new(@client).index('users', 'followed_by_int', userid.to_i)
      .map(retrieveUserInfo, {:language => 'javascript'})
      .map(unpackTimeline, {:language => 'javascript'})
      .map(attachBleatInfo, {:language => 'javascript'})
      .reduce('Riak.reduceSort', {:arg => sortDescTimestamp, :language => 'javascript', :keep => true}).run

      #For some reason, results.map didn't work. Oh well
      resultsf = []
      #M/R in Erlang JSONizes the userinfo for some reason, so we parse it here
      results.each do |tw|
           uinfo = JSON[tw['userinfo']['userinfo']]
         oinfo = {'uid' => tw['userinfo']['uid'], 'tid' => tw['tid'], 'content' => tw['content'], 'timestamp' => formatts(tw['timestamp'])}
resultsf.push(oinfo.merge(uinfo))

    end
  return resultsf
    rescue => exception
      puts $!
      puts exception.backtrace
    end
  end

def formatts timestamp
  now = Time.now
  ts = Time.at(timestamp)
  diff = Time.at(now - ts)
  if(now.year == ts.year) #same year
    if(now.day == ts.day) #same day
      if(diff.tv_sec < 3600) #w/i 60 minutes
        if(diff.tv_sec < 60) # same minute
          format = "%Ss"
        else
          format = "%Mm%Ss"
        end
      else
        format = "%Hh%Mm%Ss"
      end
      return diff.strftime(format)
    else
      format = "%b %e %H:%M"#date
    end
  else
    format = "%b %y"#year, date
  end
  return ts.strftime(format)
end
#Follow a user.
def followUser(followerid, followeeid)
  begin
      #Fetch the /users bucket.
      userBucket = @client["users"]
      #Check that both users exist.
      if(userBucket.exists?(followeeid) && userBucket.exists?(followerid))
        followee = userBucket[followeeid] #Fetch the followee object from the /users bucket.
        return if followee.indexes['followed_by_int'].include?(followerid.to_i)
        @client["users"].counter('fc_'+followerid).increment unless followeeid.eql?(followerid)#Increment the following count counter. (This is a CRDT)
        followee.indexes['followed_by_int'] << followerid.to_i #Add the followerid to the index.
        followee.store #Put the followee object back in the database.
      end
  rescue
    puts $!
    #ERROR
  end
end

#Unfollow a user.
def unfollowUser(unfollowerid, unfolloweeid)
  begin
    
      #Fetch the /users bucket.
      userBucket = @client["users"]
      if(userBucket.exists?(unfolloweeid) && userBucket.exists?(unfollowerid))

        #Decrement the followingcount counter.
        @client["users"].counter('fc_'+unfollowerid).decrement
        unfollowee = userBucket[unfolloweeid] #Get the unfollowee object in /users.
        return if !unfollowee.indexes['followed_by_int'].include?(unfollowerid.to_i)
        unfollowee.indexes['followed_by_int'].delete(unfollowerid.to_i) #Remove the unfollowee's id from the index.
        unfollowee.store #Put the unfollowee object back in the database.
      end
  rescue
    puts $!
    #ERROR
  end
end

#Create a user. We don't expose this in any way yet, but use this for testing.
def createUser(uinfo)

  #Get the /userinfo, and /users buckets
  userinfoBucket = @client["userinfo"]
  usersBucket = @client["users"]
  
  uidCounter = usersBucket.counter('max_user_id') # fetch user_id generator counter
  uid = uidCounter.value + Random.new.rand(@@new_id_range) #generate new uid, randomizing to avoid collisions
  uidCounter.increment(@@new_id_range) #increment

  #Create value (hash to be translated into JSON object) to be stored in userinfo bucket
  userIData = {
    :email => uinfo[:email],
    :password => hashpassword(uinfo[:password]).to_s,
    :uid => uid.to_s
  }

  #Create a Riak Object out of our userinfo hash.
  userRInfoObj = initRObj(userinfoBucket, uinfo[:email], "application/json",userIData)

  #Create value to be stored in users bucket
  usersData = {
    :handle => uinfo[:handle],
    :name => uinfo[:name],
    :avatarurl => uinfo[:avatarurl]
  }
  
  #Create a Riak Object out of our users hash.  
  userRObj = initRObj(usersBucket, uid.to_s, "application/json", usersData)

  #Create a new timeline object to put in the database.
  userTLObj = initRObj(@client["timelines"], uid.to_s, "application/json", {"bleat_ids" => []})

  #Create a new following_counter. (We store this so we don't have to look up every key in the bucket and check the indices.)
  Riak::Crdt::Counter.new(@client["users"], 'fc_'+uid.to_s)

  #Store all these elements in the database.
  userRObj.store
  userRInfoObj.store
  userTLObj.store

  #Link user object to corresponding user info object (just in case we need it)
  userRObj.reload
  userRObj.links << Riak::Link.new(userinfoBucket, uinfo[:email], "user_data")
	userRObj.indexes["followed_by_int"] << uid
	userRObj.store
end

#Helper function to create an Riak Object out of data.
def initRObj(bucket, key, ctype, data)
  rObj = bucket.new(key) #Associate the object with the given bucket and key. 
  rObj.content_type = ctype #Give it a mandatory content type
  rObj.data = data #Assign the data
  return rObj;
end

#Our algorithm for creating the password.
def hashpassword pswd
  BCrypt::Password.create(pswd)
end

#Gets the information about a user, and optionally checks whether you follow/don't follow/are the user.
def fetchProfile(userid,myid=nil)
  begin
    #Fetch the Riak Object corresponding to the profile.
    profileRObj = @client["users"][userid.to_s]

    #Parse the profile Riak Object's data.
    profileInfo = JSON[profileRObj.content.raw_data]

    #Compute other information we want to know
    otherInfo = {
      'uid' => userid,
      'followingcount' => @client["users"].counter("fc_"+userid.to_s).value,
      'followercount' => profileRObj.indexes["followed_by_int"].length-1,
      'user_relation' => (myid ? (userid == myid ? "is-self" : (profileRObj.indexes["followed_by_int"].include?(myid.to_i) ? "is-following" : "is-not-following")) : "unknown")}
    #Return all the information merged together
    return profileInfo.merge(otherInfo)
  rescue
    puts $!
  end
end

def getAllUsers
  userBucket = @client['users']
  user_list = []
  userBucket.keys.each do |key|
    puts key
    user_list.push(fetchProfile(key)) if key.to_i.to_s == key
  end
  return user_list.sort { |a, b| a['uid'].to_i <=> b['uid'].to_i}
end

#Get the bleats from a given user.
def retrieveBleats userid
  begin
    #Retrieve the user's timeline object.
    tlRObj = @client["timelines"][userid.to_s]
    #Parse the bleat ids.
    bleatids = JSON[tlRObj.content.raw_data]['bleat_ids']
    #Fetch the user's profile.
    uprofile = fetchProfile(userid.to_s, nil)
    #For each bleat_id, fetch the bleat information, and merge it with the author's information
    bleat_list = []
    bleatids.each do |bleatid| 
        bleatRObj = @client["bleats"][bleatid]
        bleat = JSON[bleatRObj.content.raw_data]
        bleat['timestamp'] = formatts(bleat['timestamp'])
        bleat_list.push(bleat.merge(uprofile).merge({"tid" => bleatid, "uid" => userid}))
      end
    return bleat_list
  rescue
    puts $!
  end
end
#Check if the user exists/
def userExists? userid
  return @client["users"].exists?(userid)
end

#Post a bleat.
def postBleat(userid, bleatcontent)
  begin
    #Check that the client exists.
    if (@client["users"].exists?(userid))
    #Create the bleat object.
    bleat = {
      "timestamp" => Time::now().to_i(),
      "content" => bleatcontent
    } 
    #Generate a new bleat id and increment the counter.
    bleat_id = @client["bleats"].counter('max_bleat_id').value + Random.new.rand(@@new_id_range) 
    @client["bleats"].counter('max_bleat_id').increment(100)
    bleatRObj = initRObj(@client["bleats"], bleat_id.to_s, "application/json", bleat)
     #put in database, will autoassign key
    bleatRObj.store

    timelineRObj = @client["timelines"].get_or_new(userid) #get timeline object or create if doesn't exist
    #Append the bleat to the timeline.
    timelineRObj.raw_data = appendBleatToTimeline(bleat_id.to_s, timelineRObj.raw_data)
    #Store the timeline object
    timelineRObj.store
    else
    end
  rescue
    puts $!
    #TODO: failure posting
  end
end

#Helper method to append the bleat id.
def appendBleatToTimeline(bleatID, tl)
  tidlist = JSON[tl]
  tidlist["bleat_ids"].unshift(bleatID)
  return JSON[tidlist]
end

end

#Module for authentication.
module BleaterAuth
  #Method that validates credientials.
def self.validateCredentials(email, psrd)
  begin
    #Establish connection to host
    client = Riak::Client.new(host: '104.131.186.243', pb_port: 10017)
    #Create new user info object
    uinfoRObj = client["userinfo"][email]
    #Parse user info object
    uinfo = JSON[uinfoRObj.content.raw_data]
    #Check that the passwords match
    if (BCrypt::Password.new(uinfo['password'])== psrd)
      return uinfo
    else
      return nil
    end
  rescue
    puts $!
  end
end
end
