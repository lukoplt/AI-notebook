# Editor bundle

The compiled WYSIWYG editor is committed to the repo at
`../../Sources/AINotebookApp/Resources/editor/editor.js` so end users
building the Swift Package don't need npm.

When you change `src/editor.ts` or bump deps:

```bash
cd tools/editor
npm install
npm run build
```

Commit the resulting `editor.js`.
