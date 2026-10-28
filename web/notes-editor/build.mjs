import { build } from 'esbuild'
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const root = path.dirname(fileURLToPath(import.meta.url))
const output = path.resolve(root, '../../Sources/Rustle/Resources/NotesEditor')
await mkdir(output, { recursive: true })
await build({ entryPoints: [path.join(root, 'app.mjs')], bundle: true, minify: true,
  target: ['safari17'], outfile: path.join(output, 'editor.js'), legalComments: 'eof' })
for (const file of ['index.html', 'editor.css']) await copyFile(path.join(root, file), path.join(output, file))

// Ship the permissive dependency licenses with the offline editor bundle.
const lock = JSON.parse(await readFile(path.join(root, 'package-lock.json'), 'utf8'))
const notices = ['Rustle Markdown editor — third-party notices\n']
for (const [directory, info] of Object.entries(lock.packages)) {
  if (!directory || info.dev || info.devOptional) continue
  const packageDirectory = path.join(root, directory)
  const metadata = JSON.parse(await readFile(path.join(packageDirectory, 'package.json'), 'utf8'))
  let license = ''
  for (const filename of ['LICENSE', 'LICENSE.md', 'LICENSE-MIT', 'LICENSE.txt', 'license']) {
    try { license = await readFile(path.join(packageDirectory, filename), 'utf8'); break } catch {}
  }
  if (!license) throw new Error(`Missing license for ${metadata.name}`)
  notices.push(`${metadata.name} ${metadata.version}\n${license}\n`)
}
await writeFile(path.join(output, 'THIRD_PARTY_NOTICES.txt'), notices.join('\n'))
console.log(`Bundled offline Markdown editor in ${output}`)
