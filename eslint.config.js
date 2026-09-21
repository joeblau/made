import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';

export default [
  {
    ignores: [
      '**/.astro/**',
      '**/.worker-assets/**',
      '**/.wrangler/**',
      '**/cloudflare-env.d.ts',
      '**/.turbo/**',
      '**/dist/**',
      '**/node_modules/**',
    ],
  },
  {
    ...js.configs.recommended,
    files: ['**/*.{js,mjs,cjs}'],
    languageOptions: {
      globals: { ...globals.browser, ...globals.node },
    },
  },
  ...tseslint.configs.recommended.map((config) => ({
    ...config,
    files: ['workers/**/*.{ts,tsx}'],
  })),
];
