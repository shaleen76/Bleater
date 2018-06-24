//Retrieves the information in the user object and passes it onto the next phase.
//Inputs: (value retrieved from user bucket, data about key, static arguments)
  function(userinforval, keydata, args){
    //extract user data, and get timeline id as key    
    var userinfo = Riak.mapValues(userinforval)[0];
    var userid = userinforval.key;
    return[['timelines', userid, {'uid' : userid, 'userinfo' : userinfo}]];
  }
//Outputs: [<name of the timeline bucket>, timeline key to lookup, data about user to pass on]


//Unpack the timeline object, which contains the list of tweet ids made by the user, and attach user information to each tweet as well as pass the tweet id as the keydata for the next phase to fetch the tweet content
//Inputs: (timeline value lookedup from key, userinfo passed from past phase, static args)
  function(timelinerval, userinfo, args){
    var timeline = Riak.mapValuesJson(timelinerval)[0]['tweet_ids'];  //map through timeline and return {userinfo, tweetid} object  
    return timeline.map(function(tweetid){
      return ['tweets', tweetid, userinfo]
    })
 }
//Outputs: [<name of tweet bucket>, tweet key to look up, data about user as well as the tid]

//Look up the tweet in the /tweets bucket and create the finalized, flattened tweet object.
//Inputs: (tweet value looked up from tweetid key, userinfo and tid passed from last phase, static args)
  function(tweetrval, userinfo, args){
    var tweet = Riak.mapValuesJson(tweetrval)[0];
    return [{
      'tid' : tweetrval.key,
      'timestamp' : tweet.timestamp,
      'body' : tweet.content,
      'userinfo' : userinfo
    }];
  }
//Outputs: An array with a single tweet object in it.

//Function passed as an argument to our final reduce phase (sorting the tweets in descending order by timestamp), which makes use of riak's builtin reduceSort MapReduce function
  function(t1, t2)
  {
    return t2.timestamp - t1.timestamp;
  }

