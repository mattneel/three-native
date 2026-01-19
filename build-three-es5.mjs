import { build } from "esbuild";
import { transformAsync } from "@babel/core";
import presetEnv from "@babel/preset-env";
import { promises as fs } from "node:fs";
import { resolve } from "node:path";

const entry = resolve("examples/three-entry.js");
const temp = resolve("examples/three.bundle.js");
const outfile = resolve("examples/three.es5.js");

await build({
  entryPoints: [entry],
  bundle: true,
  format: "iife",
  globalName: "THREE",
  platform: "browser",
  target: ["es2017"],
  outfile: temp,
});

const input = await fs.readFile(temp, "utf8");
const renameCatchParams = () => ({
  visitor: {
    CatchClause(path) {
      const param = path.node.param;
      if (param && param.type === "Identifier") {
        const uid = path.scope.generateUidIdentifier("err");
        path.scope.rename(param.name, uid.name);
        path.node.param = uid;
      }
    },
  },
});
const result = await transformAsync(input, {
  presets: [[presetEnv, { targets: { ie: "11" }, bugfixes: true, modules: false }]],
  plugins: [renameCatchParams],
  comments: false,
  compact: false,
});

if (!result?.code) {
  throw new Error("Babel transform failed");
}

const prelude =
  'var Symbol = typeof Symbol === "undefined" ? { iterator: "@@iterator", toStringTag: "@@toStringTag", toPrimitive: "@@toPrimitive" } : Symbol;\n';
let output = prelude + result.code;
output = output.replace(
  "function generateDefines(defines) {",
  'function generateDefines(defines) { if (defines == null) return "";'
);
output = output.replace(
  /function _classCallCheck\([^)]*\) \{[^}]*\}/,
  "function _classCallCheck() {}"
);
await fs.writeFile(outfile, output);
await fs.unlink(temp);

console.log(`Wrote ${outfile}`);
