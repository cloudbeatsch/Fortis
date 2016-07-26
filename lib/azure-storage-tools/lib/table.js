_exports = {

  detablify : (t) => {
    var o = {};
    for (var k in t) {
      if (k[0] != '.') {
        o[k] = t[k]._;
      }
    }
    return o;
  },

  tablify : (o) => {

    function add(r, k, v) {
      r[k] = { _ : v };
    }

    var row = {};
    for (var k in o) {
      if (typeof(o[k]) == 'object') {
        add(row, k, JSON.stringify(o[k]));
      }
      else {
        add(row, k, o[k]);
      }
    }

    return row;
  },

  retryOrResolve : () => {
  },

  forEach : (tableService, t, fn, cb) => {

    var processed = 0;
    function nextBatch(continuationToken) {

      tableService.queryEntities(t, null, continuationToken, (err, result) => {

        for (var entry of result.entries) {
          fn(entry);
          processed++;
        }

        if (result.continuationToken) {
          process.nextTick(() => {
            nextBatch(result.continuationToken);
          });
        }
        else {
          cb(null, processed);
        }
      });
    }

    nextBatch(null);
  }
}

module.exports = _exports;
