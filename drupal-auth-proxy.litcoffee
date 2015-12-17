HTTP Reverse Proxy that authenticates against a Drupal User account.
====

Dependencies.

    http = require 'http'
    httpProxy = require 'http-proxy'
    websrv = require 'express'
    config = require 'config'
    mysql = require 'mysql'
    os = require 'os'
    logger = require 'morgan'
    cookieParser = require 'cookie-parser'
    errorhandler = require 'errorhandler'
    wait = require 'wait.for'
    u = require 'underscore'

Read Configuration.

    app_port = config.get('appPort') || 8088
    drupal_port = config.get('drupalPort') || 80
    drupal_host = config.get('drupalHost') || 'localhost' # @todo can/should we read this from req?
    db_config =
        host: config.get('dbHost') || 'localhost',
        user: config.get('dbUser') || 'root',
        password: config.get('dbPass') || '',
        database: config.get('dbName') || 'drupal'

Manage a Database connection taht automatically reconnects as needed.

    persistentDbConnection = () ->
      connection = mysql.createConnection(db_config); # Recreate the connection, since
                                                      # the old one cannot be reused.

      connection.connect (err) ->              # The server is either down
        if err                                      # or restarting (takes a while sometimes)
          console.log('error when connecting to db:', err);
          setTimeout(persistentDbConnection, 2000); # We introduce a delay before attempting to reconnect,
                                              # to avoid a hot loop, and to allow our node script to
                                              # process asynchronous requests in the meantime.
                                              # If you're also serving http, display a 503 error.
      connection.on 'error', (err) ->
        console.log('db error', err);
        if err.code is 'PROTOCOL_CONNECTION_LOST'     # Connection to the MySQL server is usually
          persistentDbConnection();                         # lost due to either server restart, or a
        else                                          # connnection idle timeout (the wait_timeout
          throw err;                                  # server variable configures this)

      return connection

    db = persistentDbConnection()

Set-up the Proxy.

    Proxy = new httpProxy.createProxyServer()

    Proxy.on 'error', (e) ->
      console.log(e)

Set-up Express.

    app = websrv()

    app.use logger(if config.get('devMode') then 'dev' else 'default')
    app.use cookieParser()

If we're behind a trusted proxy, we'll forward some headers.

    if config.get('trustProxy')
      app.enable 'trust proxy'

The is the function that actually forwards a request to the backend service.

    forwardRequest = (req, res) ->
      res.header('Drupal-Auth-Proxy-Host', hostname)
      if config.get('devMode')
        console.log 'FORWARD: ' + req.url # @debug
      Proxy.web req, res, {target: 'http://' + drupal_host + ':' + drupal_port}, (e) ->
        console.log(e)

This function runs inside a "Fiber" which allows sychronous operations without
blocking the main event loop.

    handleRequest = (req, res) ->
      console.log(req.cookies)
      allow_access = u.chain(req.cookies)
        .keys()
        .filter (x) -> x.match(/^SESS/)
        .find (session_key) -> 
           isValidCookie(req.cookies[session_key])


      if allow_access.value()
        forwardRequest(req, res)
      else
        res.status(403)
        res.send('Access Denied.')

Here we query the Drupal data to see if a given Session ID is associated with a
logged-in user with the role required by our configuration.

    isValidCookie = (session_id) -> 
      prefix = config.get('dbPrefix') 
      query = "SELECT r.rid
                FROM #{ prefix }sessions s
                JOIN #{ prefix }users_roles r ON s.uid = r.uid
                WHERE sid = '#{ session_id }';"
      rows = wait.forMethod(db, 'query', query)
      user_roles = u.chain(rows).pluck('rid').value()
      return config.get('roleId') in user_roles

Tell express to handle all requests.

    app.all '*', (req, res, next) ->
      wait.launchFiber(handleRequest, req, res)

For some reason that I can't remember, this works best when added last.

    app.use errorhandler()

Start the server.

    http.createServer(app).listen(app_port)
    console.log("Listening on port #{ app_port }.")
