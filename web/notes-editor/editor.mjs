import { Editor } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import { Markdown } from '@tiptap/markdown'
import { TaskList, TaskItem } from '@tiptap/extension-list'
import { TableKit } from '@tiptap/extension-table'
import Placeholder from '@tiptap/extension-placeholder'
import Image from '@tiptap/extension-image'

export function createEditor(element, markdown = '', onChange = () => {}) {
  let editor
  editor = new Editor({
    element,
    extensions: [
      StarterKit.configure({
        underline: false,
        link: { openOnClick: false, autolink: true, defaultProtocol: 'https' },
      }),
      TaskList,
      TaskItem.configure({
        nested: true,
        HTMLAttributes: { 'data-type': 'taskItem' },
        a11y: { checkboxLabel: (node, checked) => `${checked ? '已完成' : '未完成'}：${node.textContent || '未命名待办'}` },
      }),
      TableKit.configure({ table: { resizable: false } }),
      Image.configure({ allowBase64: true }),
      Placeholder.configure({ placeholder: '记下想法，或粘贴 Markdown…' }),
      Markdown.configure({ markedOptions: { gfm: true } }),
    ],
    content: markdown,
    contentType: 'markdown',
    editorProps: {
      attributes: {
        'aria-label': 'Markdown 所见即所得编辑器',
        'aria-multiline': 'true',
        role: 'textbox',
        spellcheck: 'false',
      },
      handlePaste(_view, event) {
        const clipboard = event.clipboardData
        const text = clipboard?.getData('text/plain')
        if (!text || clipboard.getData('text/html')) return false
        event.preventDefault()
        editor.commands.insertContent(text, { contentType: 'markdown' })
        return true
      },
      handleClick(_view, _position, event) {
        const link = event.target.closest?.('a')
        if (link && (event.metaKey || event.ctrlKey)) {
          event.preventDefault()
          window.webkit?.messageHandlers.noteEditor.postMessage({ type: 'openLink', url: link.href })
          return true
        }
        return false
      },
    },
    onUpdate: ({ editor }) => onChange(editor.getMarkdown()),
  })
  return editor
}

export function runCommand(editor, command, value) {
  const chain = editor.chain().focus()
  switch (command) {
    case 'paragraph': return chain.setParagraph().run()
    case 'heading': return chain.setHeading({ level: Number(value) }).run()
    case 'bold': return chain.toggleBold().run()
    case 'italic': return chain.toggleItalic().run()
    case 'strike': return chain.toggleStrike().run()
    case 'code': return chain.toggleCode().run()
    case 'bulletList': return chain.toggleBulletList().run()
    case 'orderedList': return chain.toggleOrderedList().run()
    case 'taskList': return chain.toggleTaskList().run()
    case 'blockquote': return chain.toggleBlockquote().run()
    case 'codeBlock': return chain.toggleCodeBlock().run()
    case 'horizontalRule': return chain.setHorizontalRule().run()
    case 'table': return chain.insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run()
    case 'addRow': return chain.addRowAfter().run()
    case 'addColumn': return chain.addColumnAfter().run()
    case 'deleteTable': return chain.deleteTable().run()
    case 'undo': return chain.undo().run()
    case 'redo': return chain.redo().run()
    case 'link': {
      if (!value) return chain.extendMarkRange('link').unsetLink().run()
      let url
      try { url = new URL(value) } catch { return false }
      if (!['https:', 'http:', 'mailto:'].includes(url.protocol)) return false
      return chain.extendMarkRange('link').setLink({ href: url.href }).run()
    }
    default: return false
  }
}

export function loadMarkdown(editor, markdown) {
  // Loading saved content is not an edit and must never become an undo step.
  return editor.chain().setContent(markdown, { contentType: 'markdown', emitUpdate: false })
    .setMeta('addToHistory', false).run()
}
