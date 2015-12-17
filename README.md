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
- Copy `config/default.json` to `config/your.hostname.json` and fill in desired
  values.

## Run
- See or Execute `./start.sh`
