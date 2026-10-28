import { test } from 'node:test'
import assert from 'node:assert/strict'
import { JSDOM } from 'jsdom'
import { readFileSync } from 'node:fs'
import { createEditor, loadMarkdown, runCommand } from './editor.mjs'

const dom = new JSDOM('<!doctype html><html><body></body></html>', { pretendToBeVisual: true, url: 'https://notes.test' })
for (const key of ['window', 'document', 'navigator', 'Node', 'HTMLElement', 'Element', 'MutationObserver', 'DOMParser', 'getComputedStyle']) {
  Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] })
}
globalThis.requestAnimationFrame = callback => setTimeout(callback, 0)
globalThis.cancelAnimationFrame = clearTimeout
dom.window.Range.prototype.getClientRects = () => []
dom.window.Range.prototype.getBoundingClientRect = () => ({ top: 0, right: 0, bottom: 0, left: 0, width: 0, height: 0 })

function withEditor(markdown, operation, onChange) {
  const element = document.createElement('div')
  document.body.appendChild(element)
  const editor = createEditor(element, markdown, onChange)
  try { operation(editor, element) } finally { editor.destroy(); element.remove() }
}

test('Markdown appears as editable headings, marks, lists, tasks, quotes, code, links, and tables', () => {
  const markdown = '# 项目计划\n\n**重要**，*斜体*，~~删除~~ 与 `code`。\n\n- 第一项\n- 第二项\n\n1. 先做\n2. 再做\n\n- [ ] 待处理\n- [x] 已完成\n\n> 引用原文\n\n```swift\nlet greeting = "你好"\n```\n\n[官方文档](https://example.com)\n\n| 项目 | 状态 |\n| --- | --- |\n| 编辑器 | 完成 |'
  withEditor(markdown, (editor, element) => {
    assert.equal(element.querySelector('h1').textContent, '项目计划')
    assert.equal(element.querySelector('strong').textContent, '重要')
    assert.equal(element.querySelector('em').textContent, '斜体')
    assert.equal(element.querySelector('s').textContent, '删除')
    assert.equal(element.querySelectorAll('input[type=checkbox]').length, 2)
    assert.equal(element.querySelectorAll('td').length, 2)
    assert.equal(element.querySelector('blockquote').textContent, '引用原文')
    const exported = editor.getMarkdown()
    for (const token of ['# 项目计划', '**重要**', '*斜体*', '~~删除~~', '- [ ] 待处理', '- [x] 已完成', '```swift', '[官方文档](https://example.com)', '| 项目']) {
      assert.ok(exported.includes(token), `Missing ${token} in ${exported}`)
    }
    const semanticJSON = () => {
      const json = editor.getJSON()
      // Tiptap adds an empty trailing paragraph for typing after a table.
      while (json.content.at(-1)?.type === 'paragraph' && !json.content.at(-1).content) json.content.pop()
      return json
    }
    const json = semanticJSON()
    editor.commands.setContent(exported, { contentType: 'markdown', emitUpdate: false })
    assert.deepEqual(semanticJSON(), json)
    assert.equal(editor.getMarkdown().trimEnd(), exported.trimEnd())
  })
})

test('Toolbar formatting, undo, and redo update exported Markdown', () => {
  withEditor('格式测试', editor => {
    editor.commands.setTextSelection({ from: 1, to: 5 })
    assert.equal(runCommand(editor, 'bold'), true)
    assert.equal(editor.getMarkdown(), '**格式测试**')
    runCommand(editor, 'undo')
    assert.equal(editor.getMarkdown(), '格式测试')
    runCommand(editor, 'redo')
    assert.equal(editor.getMarkdown(), '**格式测试**')
    runCommand(editor, 'heading', 2)
    assert.equal(editor.getMarkdown().trimEnd(), '## **格式测试**')
  })
})

test('Task checkboxes serialize their edited checked state', () => {
  withEditor('- [ ] 检查导出', (editor, element) => {
    const checkbox = element.querySelector('input[type=checkbox]')
    checkbox.checked = true
    checkbox.dispatchEvent(new window.Event('change', { bubbles: true }))
    assert.ok(editor.getMarkdown().includes('- [x] 检查导出'))
  })
})

test('Code and image URLs survive Markdown round trips', () => {
  const markdown = '```html\n<div>**保留原样** & "引号"</div>\n```\n\n![示意图](https://example.com/image.png "图片标题")'
  withEditor(markdown, editor => {
    const exported = editor.getMarkdown()
    assert.ok(exported.includes('<div>**保留原样** & "引号"</div>'))
    assert.ok(exported.includes('![示意图](https://example.com/image.png "图片标题")'))
  })
})

test('Loading or switching content does not overwrite storage; subsequent edits report the current document', () => {
  const changes = []
  withEditor('# 原笔记', editor => {
    assert.deepEqual(changes, [])
    editor.commands.setContent('# 另一篇', { contentType: 'markdown', emitUpdate: false })
    assert.deepEqual(changes, [])
    editor.commands.insertContent('已编辑')
    assert.equal(changes.length, 1)
    assert.ok(changes[0].includes('另一篇'))
    assert.ok(!changes[0].includes('原笔记'))
  }, markdown => changes.push(markdown))
})

test('Unsupported toolbar commands and script URLs cannot change the document', () => {
  withEditor('文字', editor => {
    const before = editor.getMarkdown()
    assert.equal(runCommand(editor, 'link', 'javascript:alert(1)'), false)
    assert.equal(runCommand(editor, 'unknown'), false)
    assert.equal(editor.getMarkdown(), before)
    editor.commands.setContent('<script>alert(1)</script>\n\n[链接](javascript:alert(1))', { contentType: 'markdown' })
    assert.ok(!editor.getHTML().includes('<script'))
    assert.ok(!editor.getHTML().includes('href="javascript:'))
  })
})

test('Opening saved Markdown is not an undoable change', () => {
  withEditor('', editor => {
    loadMarkdown(editor, '# 已保存的笔记\n\n原有内容')
    assert.equal(editor.can().undo(), false)
    editor.commands.setTextSelection(editor.state.doc.content.size - 1)
    editor.commands.insertContent(' 新增')
    assert.equal(editor.can().undo(), true)
    editor.commands.undo()
    assert.ok(editor.getMarkdown().includes('原有内容'))
    assert.ok(!editor.getMarkdown().includes('新增'))
    assert.equal(editor.can().undo(), false)
  })
})

test('The native bridge sends edits but never rewrites an unedited note on focus loss', async () => {
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8')
  document.body.innerHTML = new window.DOMParser().parseFromString(html, 'text/html').body.innerHTML
  const messages = []
  window.webkit = { messageHandlers: { noteEditor: { postMessage: message => messages.push(message) } } }
  window.scrollTo = () => {}
  await import('./app.mjs')
  assert.equal(messages[0].type, 'ready')
  window.rustleNotes.load('# 已保存的笔记\n\n原有内容\n\n')
  window.dispatchEvent(new window.Event('blur'))
  assert.equal(messages.filter(message => message.type === 'change').length, 0)
  const paste = new window.Event('paste', { bubbles: true, cancelable: true })
  Object.defineProperty(paste, 'clipboardData', { value: { getData: type => type === 'text/plain' ? '追加内容' : '' } })
  document.querySelector('.tiptap').dispatchEvent(paste)
  const edited = messages.find(message => message.type === 'change')
  assert.ok(edited.markdown.includes('追加内容'))
  assert.ok(edited.markdown.includes('原有内容'))
  window.dispatchEvent(new window.Event('blur'))
  assert.equal(messages.at(-1).markdown, window.rustleNotes.getMarkdown())
})
