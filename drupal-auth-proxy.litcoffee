HTTP Reverse Proxy that authenticates against a Drupal User account.
====

Dependencies.
----
- Utility functions are provided by 'underscore'.
- File-system functions are provided by 'fs'.
- Non-blocking wrappers for synchronous functions are provided by 'wait'.
- The web server framework is 'websrv'. Currently Express is used, but it could
  be stripped out fairly easily for direct use of Node's http library or
  something else.

File a bug report if any of the other dependencies' purpose is not sufficiently
clear from the variable name.

    http = require 'http'
    httpProxy = require 'http-proxy'
    websrv = require 'express'
    https = require 'https'
    config = require 'config'
    mysql = require 'mysql'
    os = require 'os'
    logger = require 'morgan'
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

Web Server
----
Set-up Express with logging and cookie parsing.

    app = websrv()

    app.use logger(if config.get('devMode') then 'dev' else 'combined')
    app.use cookieParser()

If we're behind a trusted reverse proxy, like Varnish, we'll forward some
headers.

    if config.get('trustProxy')
      app.enable 'trust proxy'

Set-up our Proxy for relaying requests to our backend.

    Proxy = new httpProxy.createProxyServer()

    Proxy.on 'error', (error) ->
      console.log(error)

The is the function that actually forwards a request to the backend service.

    forwardRequest = (req, res) ->
      res.header('Drupal-Auth-Proxy-Host', os.hostname())
      if config.get('devMode')
        console.log 'FORWARD: ' + req.url # @debug
      Proxy.web req, res, {target: config.get('backend')}, (error) ->
        console.log(error)

This is the callback used by the web server framework.

    handleRequest = (req, res) ->
      if config.get('devMode')
        console.log(req.cookies)
      allow_access = u.chain(req.cookies)
        .keys()
        .filter (x) -> x.match(/^(S|)SESS/)
        .find (session_key) ->
           isValidCookie(req, session_key)

      if allow_access.value()
        forwardRequest(req, res)
      else
        res.status(403)
        res.send(config.get('accessDeniedMessage'))

Here we query the Drupal data to see if a given Session ID is associated with a
logged-in user with the role required by our configuration. Because of the use
of wait.forMethod(), this should be run inside a "Fiber," which is explained
below.

    isValidCookie = (req, session_key) ->
      session_id = req.cookies[session_key]

We first check a local cache.

      user_roles = cache.get(session_id)
      if not !user_roles?

When we don't already know the roles, we look them up in the Drupal database.

        prefix = config.get('dbPrefix')
        query = "SELECT r.rid
                  FROM #{ prefix }sessions s
                  JOIN #{ prefix }users_roles r ON s.uid = r.uid
                  WHERE sid = '#{ session_id }';"
        rows = wait.forMethod(db, 'query', query)
        user_roles = u.chain(rows).pluck('rid').value()

We cache query results per session for 30 seconds, to avoid look-ups for every
resource in a page request.

        cache.put(session_id, user_roles, 30000)

      return config.get('roleId') in user_roles

Tell the web server framework to handle all requests inside a "Fiber" which
allows sychronous operations without blocking the main event loop.

    app.all '*', (req, res, next) ->
      wait.launchFiber(handleRequest, req, res)

This configures the web framework with an errorhandler(). For some reason that
I can't remember, I think this works best when added last.

    app.use errorhandler()

Start the server.

    appPort = config.get('appPort')
    cert = config.get('sslCertPath')
    key = config.get('sslKeyPath')
    if fs.existsSync(cert) and fs.existsSync(key)
      options =
        "cert": fs.readFileSync(cert),
        "key": fs.readFileSync(key)
      https.createServer(options, app).listen(appPort)
    else
      console.log("Missing Certificate or key. Running without SSL.")
      http.createServer(app).listen(appPort)
    console.log("Listening on port #{ appPort }.")
