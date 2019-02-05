const cookie = require('cookie');

const _cookies = require('./_cookies');

function oneYearFromNow() {
  return new Date(Date.now() + (1000 * 60 * 60 * 24 * 365));
}

function setCookieFallback(name, value) {
  _cookies[name] = value;
}

function setCookie(name, value, expiration = oneYearFromNow()) {
  document.cookie = cookie.serialize(name, value, {expires: expiration, path: '/'});
}

if (typeof document === 'undefined' ||
    window.location.protocol === 'file:') {
  module.exports = setCookieFallback;
} else {
  module.exports = setCookie;
}
