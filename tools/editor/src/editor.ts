import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Image from "@tiptap/extension-image"
import { Markdown } from "tiptap-markdown"

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        aino?: { postMessage: (m: unknown) => void }
      }
    }
    // WebView2 (Windows) host bridge — present only under Microsoft Edge WebView2.
    chrome?: {
      webview?: { postMessage: (m: unknown) => void }
    }
    aino?: {
      setContent: (md: string) => void
      requestSave: () => void
    }
  }
}

// Transport-agnostic JS -> native send. WebView2 (Windows) delivers the object
// as JSON via window.chrome.webview.postMessage; WKWebView (macOS) delivers a
// native dict via window.webkit.messageHandlers.aino.postMessage. The same
// payload object is sent either way, so the native side decodes the identical
// { kind: ... } shape. macOS falls through to the webkit branch unchanged.
function postToSwift(payload: unknown) {
  const wv2 = window.chrome?.webview
  if (wv2 && typeof wv2.postMessage === "function") {
    wv2.postMessage(payload)
    return
  }
  window.webkit?.messageHandlers?.aino?.postMessage(payload)
}

const mount = document.getElementById("editor") as HTMLElement
const editor = new Editor({
  element: mount,
  extensions: [
    StarterKit,
    Image.configure({ inline: false, allowBase64: false }),
    Markdown.configure({ html: false, tightLists: true, linkify: true })
  ],
  content: "",
  onUpdate({ editor }) {
    const md = (editor.storage as any).markdown.getMarkdown() as string
    postToSwift({ kind: "change", markdown: md })
  }
})

window.aino = {
  setContent(md: string) {
    editor.commands.setContent(md, false)
  },
  requestSave() {
    const md = (editor.storage as any).markdown.getMarkdown() as string
    postToSwift({ kind: "save", markdown: md })
  }
}

postToSwift({ kind: "ready" })

const pendingRequests = new Map<string, (url: string | null) => void>()

const ainoExtra = {
  attachmentSaved(requestId: string, url: string, _mime: string) {
    const cb = pendingRequests.get(requestId); pendingRequests.delete(requestId)
    if (cb) cb(url)
  },
  attachmentDenied(requestId: string) {
    const cb = pendingRequests.get(requestId); pendingRequests.delete(requestId)
    if (cb) cb(null)
  }
}
Object.assign(window.aino as any, ainoExtra)

function uploadFile(file: File): Promise<string | null> {
  return new Promise(resolve => {
    const reader = new FileReader()
    reader.onerror = () => resolve(null)
    reader.onload = () => {
      const base64 = String(reader.result || "").split(",", 2)[1] || ""
      const requestId = Math.random().toString(36).slice(2)
      pendingRequests.set(requestId, resolve)
      postToSwift({
        kind: "attachment",
        requestId,
        filename: file.name || "attachment.bin",
        mime: file.type || "application/octet-stream",
        base64
      })
    }
    reader.readAsDataURL(file)
  })
}

async function insertFile(file: File) {
  const url = await uploadFile(file)
  if (!url) return
  if ((file.type || "").startsWith("image/")) {
    editor.chain().focus().setImage({ src: url, alt: file.name }).run()
  } else {
    editor.chain().focus().insertContent(`[${file.name}](${url})`).run()
  }
}

mount.addEventListener("paste", (e) => {
  const items = (e as ClipboardEvent).clipboardData?.items
  if (!items) return
  for (let i = 0; i < items.length; i++) {
    const it = items[i]
    if (it.kind === "file") {
      const f = it.getAsFile()
      if (f) {
        e.preventDefault()
        insertFile(f)
      }
    }
  }
})

mount.addEventListener("drop", (e) => {
  const dt = (e as DragEvent).dataTransfer
  if (!dt || dt.files.length === 0) return
  e.preventDefault()
  for (let i = 0; i < dt.files.length; i++) {
    insertFile(dt.files[i])
  }
})

mount.addEventListener("dragover", (e) => {
  e.preventDefault()
})
