import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import tailwindcss from "@tailwindcss/vite";

// https://vitejs.dev/config/
export default defineConfig({
	base: "./",
	plugins: [svelte(), tailwindcss()],
	build: {
		rollupOptions: {
			input: {
				popup: "popup.html",
			},
		},
		rolldownOptions: {
			input: {
				popup: "popup.html",
			},
			optimization: {
				inlineConst: true,
			},
			treeshake: {
				moduleSideEffects: false,
			},
		},
		emptyOutDir: true,
	},
});
