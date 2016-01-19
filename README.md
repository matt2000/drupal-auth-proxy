# Drupal Auth Proxy
A NodeJS proxy written in literate coffeescript that only forwards requests 
only if the user has a valid Drupal Session cookie for a user with a given role
on a given Drupal 7 site.

## Dependencies
- NodeJS v.0.10+
- npm package manager

## Install
- `npm install`

## Configure
- Copy `config/default.json` to `config/production.json` and fill in desired
  values.
- We use the node config module, so various naming schemes are supported for
  maintaining multiple different configurations. See, e.g.,
  https://github.com/lorenwest/node-config/wiki/Configuration-Files#file-formats
- We need to be able to read your Drupal site's cookies, so that means this
  needs to run on the same domain, or a sub-domain, of the Drupal site. See
  settings.php at the definition of $cookie_domain.

## Run
- See or Execute `./start.sh`
- For debugging, you might want to run
  `NODE_ENV='development' ./node_modules/.bin/coffee drupal-auth-proxy.litcoffee`
  See: http://expressjs.com/en/advanced/best-practice-performance.html#env
