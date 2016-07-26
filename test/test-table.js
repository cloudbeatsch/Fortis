var test = require("tape");
var nconf = require("nconf");
var azure = require("azure");
var table = require("../lib/azure-storage-tools").table;

require("https").globalAgent.maxSockets = 128;

var TABLE = "test";

var config = nconf.env().file({ file: '../../localConfig.json' });

var tableService = azure.createTableService(
  config.get("AZURE_STORAGE_ACCOUNT"),
  config.get("AZURE_STORAGE_ACCESS_KEY")
);

/*
tableService.createTableIfNotExists(TABLE, (err, result) => {
  for (var partKey = 0; partKey < 10; partKey++) {
    for (var rowKey = 0; rowKey < 10000; rowKey++) {

      var row = table.tablify({
        PartitionKey: partKey.toString(),
        RowKey: rowKey.toString(),
        count: 0
      });

      tableService.insertOrReplaceEntity(TABLE, row, (err, result) => {
        if (err) {
          console.warn(err);
        }
      });
    }
  }
});
*/

/*
test("forEach", (t) => {
  t.skip();
  table.forEach(tableService, TABLE, (e) => {
  },
  (err, result) => {
    if (err) {
      t.fail(err);
    }
    else {
      t.equal(result, 10 * 10000);
      t.end();
    }
  });
});
*/

test("tablify/detablify", (t) => {

  var query = new azure.TableQuery().where("PartitionKey == '?'", 0).and("RowKey == '?'", 0);
  tableService.queryEntities(TABLE, query, null, (err, result) => {
    if (err) {
      t.fail(err);
    }
    else {
      var entry = table.detablify(result.entries[0]);
      t.assert("count" in entry);
      t.assert(typeof(entry.count) == "number");

      entry.count++;
      entry = table.tablify(entry);

      tableService.insertOrReplaceEntity(TABLE, entry, (err, result) => {
        if (err) {
          t.fail(err);
        }
        else {
          t.end();
        }
      });
    }
  });
});
