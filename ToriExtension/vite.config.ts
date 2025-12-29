import { defineConfig, minify } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

// https://vitejs.dev/config/
export default defineConfig({
  base: './',
  plugins: [svelte()],
  build: {
    rollupOptions: {
      input: {
        popup: 'popup.html',

      },

    },
    rolldownOptions: {
      input: {
        popup: 'popup.html',
      },
      optimization: {
        inlineConst: true
      },
      treeshake: {
        moduleSideEffects: false
      }

    },
    emptyOutDir: true,
  },
})
