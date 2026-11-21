// Lets `node --test web/test/` work: Node treats a directory argument as a module path, which loads this
// file, and this file loads every *.test.mjs next to it. `node --test web/test/*.test.mjs` also works.
const { readdirSync } = require("node:fs");
const { join } = require("node:path");
const { pathToFileURL } = require("node:url");
for (const f of readdirSync(__dirname).filter((n) => n.endsWith(".test.mjs")).sort()) {
  import(pathToFileURL(join(__dirname, f)).href);
}
