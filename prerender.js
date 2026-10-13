// Inlines the server-rendered page into dist/index.html so crawlers get full HTML.
import fs from 'node:fs'
import { render } from './dist-ssr/entry-server.js'

const file = 'dist/index.html'
fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('<!--app-->', render()))
fs.rmSync('dist-ssr', { recursive: true })
