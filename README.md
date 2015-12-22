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
- We need to be able to read your Drupal site's cookies, so that means this
  needs to run on the same domain, or a sub-domain, of the Drupal site. See
  settings.php at the definition of $cookie_domain.

## Run
- See or Execute `./start.sh`
