import { createEditor, loadMarkdown, runCommand } from './editor.mjs'

const send = message => window.webkit?.messageHandlers.noteEditor.postMessage(message)
let initialized = false
let edited = false
const editor = createEditor(document.querySelector('#editor'), '', markdown => {
  if (initialized) { edited = true; send({ type: 'change', markdown }) }
})
window.rustleNotes = {
  load(markdown) {
    loadMarkdown(editor, markdown)
    edited = false
    initialized = true
    refreshToolbar()
    requestAnimationFrame(() => window.scrollTo(0, 0))
  },
  getMarkdown: () => editor.getMarkdown(),
}

function refreshToolbar() {
  const toggles = new Set(['bold', 'italic', 'strike', 'code', 'bulletList', 'orderedList', 'taskList', 'blockquote', 'codeBlock'])
  document.querySelectorAll('[data-command]').forEach(button => {
    const command = button.dataset.command
    if (toggles.has(command)) button.setAttribute('aria-pressed', String(editor.isActive(command)))
    if (command === 'undo' || command === 'redo') button.disabled = !editor.can()[command]()
  })
  const heading = editor.getAttributes('heading').level
  document.querySelector('#block-style').value = heading ? String(heading) : 'paragraph'
  document.querySelector('#table-actions').hidden = !editor.isActive('table')
}
editor.on('selectionUpdate', refreshToolbar)
editor.on('transaction', refreshToolbar)
document.querySelector('#toolbar').addEventListener('mousedown', event => {
  if (event.target.closest('button')) event.preventDefault()
})
document.querySelector('#toolbar').addEventListener('click', event => {
  const button = event.target.closest('[data-command]')
  if (button && !button.disabled) runCommand(editor, button.dataset.command)
})
document.querySelector('#block-style').addEventListener('change', event => {
  const value = event.target.value
  runCommand(editor, value === 'paragraph' ? 'paragraph' : 'heading', value)
})
const linkPanel = document.querySelector('#link-panel')
const linkInput = document.querySelector('#link-url')
document.querySelector('#link-button').addEventListener('click', () => {
  linkPanel.hidden = !linkPanel.hidden
  if (!linkPanel.hidden) {
    linkInput.value = editor.getAttributes('link').href ?? ''
    linkInput.focus()
  }
})
linkPanel.addEventListener('submit', event => {
  event.preventDefault()
  if (runCommand(editor, 'link', linkInput.value.trim())) linkPanel.hidden = true
  else linkInput.setCustomValidity('请输入完整的 https://、http:// 或 mailto: 地址')
  linkInput.reportValidity()
})
linkInput.addEventListener('input', () => linkInput.setCustomValidity(''))
document.querySelector('#cancel-link').addEventListener('click', () => { linkPanel.hidden = true; editor.commands.focus() })
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && !linkPanel.hidden) {
    linkPanel.hidden = true
    editor.commands.focus()
    event.preventDefault()
  }
})
window.addEventListener('blur', () => { if (initialized && edited) send({ type: 'change', markdown: editor.getMarkdown() }) })
window.addEventListener('error', () => send({ type: 'error', message: '编辑器加载失败，请重新打开此笔记。' }))
send({ type: 'ready' })
