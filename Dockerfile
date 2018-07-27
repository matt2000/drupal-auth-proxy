FROM  node:10-alpine

WORKDIR /opt/drupal-auth-proxy/

ADD * .

RUN npm install

COPY config/default.json config/development.json

ENV NODE_ENV=development

CMD ["./node_modules/.bin/coffee drupal-auth-proxy.litcoffee"]
