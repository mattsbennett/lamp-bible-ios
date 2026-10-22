import { defineConfig } from 'vite'
import { viteSingleFile } from 'vite-plugin-singlefile'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  root: 'src',
  plugins: [viteSingleFile()],
  resolve: {
    alias: [
      // The page decodes entities itself (src/entities-browser.js).
      { find: /^entities$/, replacement: fileURLToPath(new URL('./src/entities-browser.js', import.meta.url)) },
    ],
  },
  build: {
    outDir: '../../Lamp Bible/Resources/TipTapEditor',
    emptyOutDir: true,
    target: 'es2020',
  },
})
