process.env['NODE_TLS_REJECT_UNAUTHORIZED'] = 0;

const hooks = require('hooks');

hooks.beforeEach(function (transaction) {
  transaction.request['headers']['Authorization'] = `Bearer ${process.env.ORG}`
});
