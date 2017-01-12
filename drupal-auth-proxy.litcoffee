HTTP Reverse Proxy that authenticates against a Drupal User account.
====

Dependencies.
----
- Utility functions are provided by 'underscore'.
- File-system functions are provided by 'fs'.
- Non-blocking wrappers for synchronous functions are provided by 'wait'.
- The web server 'websrv' is powered by Express and Helmet and improves HTTP
  security.

File a bug report if any of the other dependencies' purpose is not sufficiently
clear from the variable name.

    http = require 'http'
    httpProxy = require 'http-proxy'
    websrv = require 'express'
    https = require 'https'
    helmet = require 'helmet'
    config = require 'config'
    mysql = require 'mysql'
    os = require 'os'
    cookieParser = require 'cookie-parser'
    errorhandler = require 'errorhandler'
    wait = require 'wait.for'
    u = require 'underscore'
    fs = require 'fs'
    cache = require 'memory-cache'

Database
----
Read DB Configuration.

    db_config =
        host: config.get('dbHost'),
        user: config.get('dbUser'),
        password: config.get('dbPass'),
        database: config.get('dbName')

Manage a Database connection that automatically reconnects as needed.

    persistentDbConnection = () ->
      connection = mysql.createConnection(db_config);

      connection.connect (err) ->

Recreate the connection, since the old one cannot be reused. The server could be
down temporarily.

        if err
          console.log('error when connecting to db:', err);

We introduce a delay before attempting to reconnect, to avoid a hot loop. Andj
to allow our node script to process asynchronous requests in the meantime, if
there's anything that can be done without a database connection.

          setTimeout(persistentDbConnection, 2000);

      connection.on 'error', (err) ->
        console.log('db error', err);

Connection to the MySQL server is usually lost due to either server restart,
or a connnection idle timeout. (The wait_timeout mysql variable configures
this.)

        if err.code is 'PROTOCOL_CONNECTION_LOST'
          persistentDbConnection();
        else
          throw err;

      return connection

Instantiate the database connection in a global object.

    db = persistentDbConnection()

Proxy set-up
----

Set-up our Proxy for relaying requests to our backend.

    Proxy = new httpProxy.createProxyServer()

    Proxy.on 'error', (error) ->
      console.log(error)

    Proxy.on 'proxyReq', (proxyReq, req, res, options) ->
      proxyReq.setHeader('X-Drupal-UID', req.drupal_uid)
      proxyReq.setHeader('X-Drupal-session', req.drupal_session)

    Proxy.on 'proxyRes', (proxyRes, req, res) ->
      if config.get('devMode')
        console.log('PROXY RESPONSE CODE: ' + JSON.stringify(proxyRes.statusCode))

Utility Functions
----

Collect all the data for logging into a string.

    logger = (req, res) ->
      log_data =
        remote_ip: req.ip
        drupal_uid: req.drupal_uid
        request_time_utc: req.received_time.toUTCString()
        http_method: req.method
        request_url: req.url
        response_code: res.statusCode
        content_length: res.get('content-length')
        referrer: req.headers['referer'] || req.headers['referrer']
        user_agent: req.headers['user-agent']
        drupal_session: req.drupal_session
        is_authorized: res.is_authorized.toString()

      return JSON.stringify(log_data)

This is the callback used by the web server framework.

    handleRequest = (req, res) ->
      req.drupal_uid = getDrupalUserId(req)
      req.received_time = new Date()
      if config.get('devMode')
        console.log(req.cookies)
      sessions = getSessionCookies(req)
      authorized_session = u.chain(sessions).find (session_key) ->
        isAuthorized(req, session_key)

      req.drupal_session = req.cookies[authorized_session.value()] || req.cookies[sessions[0]]

      if authorized_session.value()
        res.is_authorized = true
        forwardRequest(req, res)
      else
        res.is_authorized = false
        res.status(403)
        console.log(logger(req, res))
        res.send(config.get('accessDeniedMessage'))

The is the function that actually forwards a request to the backend
service.

    forwardRequest = (req, res) ->
      res.header('X-Drupal-UID', req.uid)
      res.header('X-Client-IP', req.hostname)
      if config.get('devMode')
        res.header('Drupal-Auth-Proxy-Host', os.hostname())
      if config.get('devMode')
        console.log 'FORWARD: ' + req.url
      console.log(logger(req, res))
      Proxy.web req, res, {
          target: config.get('backend'),
          xfwd: true
        }, (error) ->
        console.log(error)


This function returns any session cookie keys.

    getSessionCookies = (req) ->
      u.chain(req.cookies)
        .keys()
        .filter (x) -> x.match(/^(S|)SESS/)
        .value()

Return the IDs of the Drupal Roles for a given user session.
Because of the use of wait.forMethod(), this must be run inside a
"Fiber," which is explained below.

    getDrupalRoles = (req, session_key) ->
      session_id = req.cookies[session_key]

We first check a local cache.

      user_roles = cache.get(session_id)
      if not user_roles?

When we don't already know the roles, we look them up in the Drupal
database.

        prefix = config.get('dbPrefix')
        query = "SELECT r.rid
                  FROM #{ prefix }sessions s
                  JOIN #{ prefix }users_roles r ON s.uid = r.uid
                  WHERE sid = '#{ session_id }';"
        rows = wait.forMethod(db, 'query', query)
        user_roles = u.chain(rows).pluck('rid').value()

We cache query results per session for 5 seconds, to avoid look-ups for
every resource in a page request.

        cache.put(session_id, user_roles, 5000)

      return user_roles

Here we query the Drupal data to see if a given Session ID is associated
with a logged-in user with the role required by our configuration.

    isAuthorized = (req, session_key) ->
      user_roles = getDrupalRoles(req, session_key)

If we didn't find any roles, deny access.

      if user_roles.length < 1
        return false

Here we can support different role requirements by path. We match by
removing subpaths in the request url until we find a match in the
configuration, or reach the root, at which point we use the default role Id.

      if config.get("devMode")
        console.log('Drupal Roles: ' + user_roles)

      if config.has('roleIdPath')
        path_to_lookup = req.path

Check for an exact match.

        if config.get('roleIdPath').has(path_to_lookup)
          return config.get('roleIdPath').get(path_to_lookup) in user_roles

Remove sub-paths until we have a path that is configured, or the root.

        while path_to_lookup.length > 1 and not config.get('roleIdPath').has(path_to_lookup)
          split = path_to_lookup.split("/")
          split.pop()
          path_to_lookup = split.join("/")
          if config.get("devMode")
            console.log('Look-up: `' + path_to_lookup + '`')

        if config.get('roleIdPath').has(path_to_lookup)
          return config.get('roleIdPath').get(path_to_lookup) in user_roles

At this point, we didn't find a configured path, so we use the default.

      if config.get("devMode")
        console.log('Root fallback.')
      return config.get('roleId') in user_roles

This function finds a Drupal User ID for the user, if available, or returns 0.

    getDrupalUserId = (req) ->
      uid = 0
      cookies = getSessionCookies(req)
      while uid == 0 and cookies.length > 0
        session_key = cookies.pop()
        lookup = queryUid(req.cookies[session_key])
        if lookup > 0
          uid = lookup
          if isAuthorized(req, session_key)
            break
      req.uid = uid
      return uid

Query the Drupal database for the user ID of a session ID.

    queryUid = (session_id) ->
      uid = cache.get("uid/" + session_id)
      if not uid?
        msg = "UID query: "
        prefix = config.get('dbPrefix')
        sql = "SELECT uid
		 FROM #{ prefix }sessions
		 WHERE sid = '#{ session_id }'
		 LIMIT 1;"
        query_result = wait.forMethod(db, 'query', sql)

        uid = query_result[0]?.uid
        # Cache for 5 minutes.
        cache.put("uid/" + session_id, uid, 300000)
      if config.get("devMode")
        msg ?= "UID from cache: "
        console.log(msg + uid)
      return uid

Start the Web server.
----

Set-up Express with cookie parsing and HSTS.

    app = websrv()
    app.use cookieParser()

    if !config.get('devMode')
      app.disable('x-powered-by')

    ONE_YEAR = 31536000000
    app.use helmet.hsts
      maxAge: ONE_YEAR
      includeSubdomains: true
      force: true

If we're behind a trusted reverse proxy, like Varnish, we'll forward some
headers.

    if config.get('trustProxy')
      app.enable 'trust proxy'

Tell the web server framework to handle all requests inside a "Fiber"
which allows sychronous operations without blocking the main event loop.

    app.all '*', (req, res, next) ->
      wait.launchFiber(handleRequest, req, res)

This configures the web framework with an errorhandler(). For some
reason that I can't remember, I think this works best when added last.

    app.use errorhandler()

Configure server port & SSL.

    appPort = config.get('appPort')
    cert = config.get('sslCertPath')
    key = config.get('sslKeyPath')
    if fs.existsSync(cert) and fs.existsSync(key)
      options =
        "secureOptions": require('constants').SSL_OP_NO_TLSv1,
        "cert": fs.readFileSync(cert),
        "key": fs.readFileSync(key)
      https.createServer(options, app).listen(appPort)
    else
      console.log("Missing Certificate or key. Running without SSL.")
      http.createServer(app).listen(appPort)
    if config.get('devMode')
      console.log("Listening on port #{ appPort }.")
