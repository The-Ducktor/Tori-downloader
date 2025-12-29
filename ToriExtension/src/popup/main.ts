import { mount } from 'svelte';
import './index.css';
import App from './App.svelte';

const target = document.getElementById('root');

if (!target) {
  throw new Error('Root element not found');
}

const app = mount(App, {
  target,
});

export default app;
