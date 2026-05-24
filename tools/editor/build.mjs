import { build } from "esbuild"

await build({
  entryPoints: ["src/editor.ts"],
  bundle: true,
  minify: true,
  format: "iife",
  target: ["safari16"],
  outfile: "../../Sources/AINotebookApp/Resources/editor/editor.js",
  loader: { ".ts": "ts" },
  logLevel: "info"
})
