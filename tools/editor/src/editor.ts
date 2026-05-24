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
    aino?: {
      setContent: (md: string) => void
      requestSave: () => void
    }
  }
}

function postToSwift(payload: unknown) {
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
