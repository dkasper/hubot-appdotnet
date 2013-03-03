{Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, Response} = require 'hubot'

HTTPS = require 'https'
{EventEmitter} = require('events')

class Adn extends Adapter
	run: ->
		@options = 
			token: process.env.HUBOT_ADN_TOKEN
			channel: process.env.HUBOT_ADN_CHANNEL

		@client = new AdnClient(@options.token, @options.channel)
		@client.watchstream()

		@client.on 'online', => @online()
		@client.on 'receivedmessage', (msg) => @handleMessage(msg)

	online: ->
		self = @
		console.log "adn client online"
		self.emit "connected"

	handleMessage: (msg) ->
		user = @getUser msg.user.username
		user.type = 'adn'
		@receive new TextMessage(user, msg.text)

	getUser: (username) ->
		user = @userForId username,
			name: username
			user: username
			domain: 'app.net'

		return user

	send: (envelope, strings...) ->
		for str in strings
			@client.send str
	
	error: (err) ->
		console.error err

class AdnClient extends EventEmitter
	constructor: (@token, @channel) ->
		@domain = "alpha-api.app.net"

	# listen for activity in channels
	watchstream: ->
		self = @

		headers =
			"Host": "stream-channel.app.net"

		options =
			"agent"  : false
			"host"   : "stream-channel.app.net"
			"port"   : 443
			"path"   : @channel
			"method" : "GET"
			"headers": headers

		request = HTTPS.request options, (response) ->
			response.setEncoding("utf8")

			buf = ''

			response.on 'connect', ->
				self.emit 'online'

			response.on "data", (chunk) ->
				if chunk is ' '
				  # campfire api sends a ' ' heartbeat every 3s

				else if chunk.match(/^\s*Access Denied/)
				  # errors are not json formatted
				  console.log "App.net error on channel #{@channel}: #{chunk}"

				else
					# api uses newline terminated json payloads
					# buffer across tcp packets and parse out lines
					buf += chunk

					while (offset = buf.indexOf("\r")) > -1
						part = buf.substr(0, offset)
						buf = buf.substr(offset + 1)

						if part
							try
								data = JSON.parse part
								if data.data.text
									self.emit 'receivedmessage', data.data
							catch error
								console.log(error)

			response.on "end", ->
				console.log "Streaming connection closed for channel #{@channel}. :("
				setTimeout (->
					self.emit "reconnect", @channel
				), 5000

			response.on "error", (err) ->
				console.log "App.net response error: #{err}"

		request.on "error", (err) ->
			console.log "App.net request error: #{err}"

		request.end()

	send: (user, message) ->
		body = { "text": message }
		@post "/stream/0/channels/#{@channel}/messages", body, (response) ->
			console.log(response)

	get: (path, callback) ->
		@request "GET", path, null, callback

	post: (path, body, callback) ->
		@request "POST", path, body, callback

	put: (path, body, callback) ->
		@request "PUT", path, body, callback

	request: (method, path, body, callback) ->
		headers =
			"Content-Type"  : "application/json"
			"Authorization" : "Bearer #{@token}"

		options =
			"agent"  : false
			"host"   : @domain
			"port"   : 443
			"path"   : path
			"method" : method
			"headers": headers

		if method is "POST" || method is "PUT"
			if typeof(body) isnt "string"
				body = JSON.stringify body

			body = new Buffer(body)
			options.headers["Content-Length"] = body.length

		request = HTTPS.request options, (response) ->
			data = ""

			response.on "data", (chunk) ->
				data += chunk

			response.on "end", ->
				if response.statusCode >= 400
					switch response.statusCode
						when 401
							throw new Error "Invalid access token provided, app.net refused the authentication"
						else
							console.log "App.net error: #{response.statusCode}"

				try
					callback null, JSON.parse(data)
				catch error
					callback null, data or { }

			response.on "error", (err) ->
				console.log "App.net response error: #{err}"
				callback err, { }

		if method is "POST" || method is "PUT"
			request.end(body, 'binary')
		else
			request.end()

exports.use = (robot) ->
	new Adn robot
