/// <reference types="vitest/config" />
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import angular from '@analogjs/vite-plugin-angular';
import { defineConfig } from 'vitest/config';

const ROOT_DIR = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [angular({ tsconfig: path.resolve(ROOT_DIR, 'tsconfig.spec.json') })],
  resolve: {
    alias: {
      'ra8-rpc-client': path.resolve(ROOT_DIR, 'client/src/index.ts'),
    },
  },
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['tests/test-setup.ts'],
    include: ['tests/**/*.spec.ts', 'tests/**/*.test.ts'],
    reporters: ['default'],
  },
});
