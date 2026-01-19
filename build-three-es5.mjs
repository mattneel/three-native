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
  generatorOpts: {
    // Keep output ASCII-safe for engines with strict parsers.
    jsescOption: { minimal: false },
  },
});

if (!result?.code) {
  throw new Error("Babel transform failed");
}

const prelude =
  'var Symbol = typeof Symbol === "undefined" ? { iterator: "@@iterator", toStringTag: "@@toStringTag", toPrimitive: "@@toPrimitive" } : Symbol;\n';
let output = prelude + result.code;
// Normalize line endings to LF for consistent parsing.
output = output.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
// Escape any non-ASCII characters that might slip through.
output = output.replace(/[^\x09\x0A\x0D\x20-\x7E]/g, (ch) => {
  const hex = ch.charCodeAt(0).toString(16).padStart(4, "0");
  return "\\u" + hex;
});
output = output.replace(
  "function generateDefines(defines) {",
  'function generateDefines(defines) { if (defines == null) return "";'
);
output = output.replace(
  /function _classCallCheck\([^)]*\) \{[^}]*\}/,
  "function _classCallCheck() {}"
);
await fs.writeFile(outfile, output, "utf8");
await fs.unlink(temp);

console.log(`Wrote ${outfile}`);
