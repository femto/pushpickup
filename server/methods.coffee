# populated at server startup
adverbs = []
leader_words = []
things = []
adjectives = []

strange =
  username: (name) ->
    tries = 0
    loop
      noun = if name
        _.string.slugify(name)
      else
        Random.choice(leader_words)
      uname = _.string.join "-",
        Random.choice(adverbs), Random.choice(adjectives), noun
      break unless Meteor.users.findOne username: uname
      tries += 1
      console.log "#{tries} tries for strange.username!" if tries > 10
    uname
  password: () ->
    _.string.join "-", _.random(10,99),
      Random.choice(adverbs), Random.choice(adjectives), Random.choice(things)

tentativeUserInfo = (username, password) ->
  "Your username is #{username} and your password is #{password}."

alertWithin = (gameId, message) ->
  console.log message

Meteor.methods
  "isEmailAvailable": (email) ->
    check(email, ValidEmail)
    emailOwner = Meteor.users.findOne({'emails.address': email})
    if _.find(emailOwner?.emails, (e) -> (e.address is email) and e.verified)
      return false
    if emailOwner
      # email is in system but unverified. remove it before proceeding.
      Meteor.users.update emailOwner?._id,
        $pull: emails: address: email
    true
  "dev.addSelfAndFriends": (friends, gameId) ->
    check(friends, [Match.Any])
    if not this.userId
      throw new Meteor.Error 401, "Must be signed in"
    Meteor.call "addSelf", gameId: gameId
    Meteor.call("dev.addFriends", gameId, friends) if friends.length > 0
    "ok"
  "dev.unauth.addSelfAndFriends": (gameId, email, name, friends) ->
    check(friends, [Match.Any])
    adder = Meteor.call "dev.unauth.addSelf", gameId, email, name
    this.setUserId adder.userId
    Meteor.call("dev.addFriends", gameId, friends) if friends.length > 0
    adder # client may want adder.password to loginWithPassword

  # This method, which sends no verification email, is intended to compose
  # with another method that *will* send a verification email
  "dev.addUser": (email, name) ->
    check(email, ValidEmail)
    check(name, NonEmptyString)
    emailOwner = Meteor.users.findOne({'emails.address': email})
    if _.find(emailOwner?.emails, (e) -> (e.address is email) and e.verified)
      throw new Meteor.Error 403,
        "Someone has already added and verified that email address"
    if emailOwner
      # email is in system but unverified. remove it before proceeding.
      Meteor.users.update emailOwner?._id,
        $pull: emails: address: email
    password = strange.password()
    userId = Accounts.createUser
      email: email
      password: password
      profile: name: name
    userId: userId, password: password

  "dev.signUp": (email, name, password) ->
    check(email, ValidEmail)
    check(name, NonEmptyString)
    check(password, ValidPassword)
    emailOwner = Meteor.users.findOne({'emails.address': email})
    if _.find(emailOwner?.emails, (e) -> (e.address is email) and e.verified)
      throw new Meteor.Error 403,
        "Someone has already added and verified that email address"
    if emailOwner
      # email is in system but unverified. remove it before proceeding.
      Meteor.users.update emailOwner?._id,
        $pull: emails: address: email
    userId = Accounts.createUser
      email: email
      password: password
      profile: name: name
    this.unblock()
    sendVerificationEmail userId, email
    "ok"
  "dev.unauth.addGame": (email, name, game) ->
    newUser = Meteor.call "dev.addUser", email, name
    this.setUserId(newUser.userId)
    result = Meteor.call "addGame", game
    this.unblock()
    sendEnrollmentEmail newUser.userId,
      email: email, thankYouFor: "adding a game", gameId: result.gameId
    _.extend(newUser, result) # {userId, password, gameId}
  "dev.unauth.addSelf": (gameId, email, name) ->
    this.unblock()
    newUser = Meteor.call "dev.addUser", email, name
    Games.update gameId,
      $push: players: name: name, userId: newUser.userId, rsvp: "in"
    maybeMakeGameOn gameId
    notifyOrganizer gameId, joined:
      userId: newUser.userId, name: name
    sendEnrollmentEmail newUser.userId,
      email: email, thankYouFor: "joining a game", gameId: gameId
    newUser
  "dev.unauth.addCommenter": (gameId, email, name, comment) ->
    newUser = Meteor.call "dev.addUser", email, name
    this.setUserId(newUser.userId)
    Meteor.call "addComment", comment, gameId
    this.unblock()
    sendEnrollmentEmail newUser.userId,
      email: email, thankYouFor: "adding a comment to a game", gameId: gameId
    newUser
  "dev.unauth.addUserSub": (email, name, types, days, region) ->
    newUser = Meteor.call "dev.addUser", email, name
    this.setUserId(newUser.userId)
    Meteor.call "addUserSub", types, days, region
    this.unblock()
    sendEnrollmentEmail newUser.userId,
      email: email, thankYouFor: "subscribing to game announcements"
    newUser
  "dev.addFriends": (gameId, friends) ->
    this.unblock()
    self = this
    if not self.userId
      throw new Meteor.Error 401, "Must be signed in"
    if friends.length is 0
      throw new Meteor.Error 400, "Must give one or more friends"
    for friend in friends
      Meteor.call "dev.addFriend", gameId, friend
    user = Meteor.users.findOne self.userId
    name = user.profile.name or "Someone"
    notifyOrganizer gameId, joined:
      userId: user._id, name: name, numFriends: friends.length
    "ok"
  "dev.addFriend": (gameId, friend) ->
    self = this
    if not self.userId
      throw new Meteor.Error 401, "Must be signed in"
    check(gameId, String)
    if not Games.findOne(gameId)
      throw new Meteor.Error 404, "Game not found"
    check(friend, {name: String, email: Match.Optional(ValidEmail)})

    if _.isEmpty friend.email
      Games.update gameId,
        $push: players: name: friend.name, friendId: self.userId, rsvp: "in"
    else
      emailOwner = Meteor.users.findOne({'emails.address': friend.email});
      if emailOwner
        unless Games.findOne({_id: gameId, 'players.userId': emailOwner._id})
          Games.update gameId,
            $push: players:
              name: friend.name
              friendId: self.userId
              userId: emailOwner._id
              rsvp: "in"
          Meteor.call "notifyAddedFriend",
            addedId: emailOwner._id, gameId: gameId, adderId: self.userId
      else
        newUserId = Accounts.createUser
          email: friend.email
          profile: name: friend.name
        Games.update gameId,
          $push: players:
            name: friend.name
            friendId: self.userId
            userId: newUserId
            rsvp: "in"
        Meteor.call "notifyAddedFriend",
          addedId: newUserId, gameId: gameId, adderId: self.userId
    maybeMakeGameOn gameId
  "addUserSub": (types, days, region) ->
    # DEACTIVATED for now
    return false

    self = this
    user = Meteor.users.findOne(self.userId)
    # `sendGameAddedNotification` sends only to verified email addresses,
    # so don't need to check for verified email address here.
    return false if not user
    check types, [GameType]
    check days, [Day]
    check region, GeoJSONPolygon
    days = [0,1,2,3,4,5,6] if _.isEmpty days
    types = _.pluck(GameOptions.find(option: "type").fetch(), 'value') if _.isEmpty types
    UserSubs.insert
      userId: self.userId
      types: types
      days: days
      region: region
  # Email game participants who wish to be notified of each new comment
  # Takes a game _id and the timestamp of the new comment
  "notifyCommentListeners": (gameId, cTimestamp) ->
    this.unblock() # sending email can take a while
    # For now, just notify the game creator
    game = Games.findOne(gameId)
    comment = _.find(game?.comments, (c) -> +c.timestamp is +cTimestamp)
    return false if not game or not comment
    return false if comment.userId is game.creator.userId
    creator = Meteor.users.findOne(game.creator.userId)
    sendEmail
      from: emailTemplates.from
      to: "#{creator.profile.name} <#{creator.emails[0].address}>"
      subject: "New comment/question on your " +
        "#{utils.displayTime(game)} #{game.type} game"
      text: "#{comment.userName} just said: \"#{comment.message}\".\n\n" +
        "For your reference, [here](#{Meteor.absoluteUrl('g/'+gameId)}) " +
        "is a link to your game.\n\nThanks for organizing!"

Meteor.startup ->
  adverbs = _.string.lines(Assets.getText("positive-adverbs-that-are-adjectives-without-ly.txt"))
  leader_words = _.string.lines Assets.getText "leader-synonyms.txt"
  things = _.string.lines Assets.getText "things-plurals.txt"
  adjectives = _.map adverbs, (adv) -> adv.slice(0,-2)

  console.log "blank things!" if _.any things, _.string.isBlank
  console.log "blank adverb!" if _.any adverbs, _.string.isBlank
  console.log "blank noun!" if _.any leader_words, _.string.isBlank


