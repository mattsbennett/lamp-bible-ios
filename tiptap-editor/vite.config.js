import { defineConfig } from 'vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

export default defineConfig({
  root: 'src',
  plugins: [viteSingleFile()],
  build: {
    outDir: '../../Lamp Bible/Resources/TipTapEditor',
    emptyOutDir: true,
    target: 'es2020',
  },
})
