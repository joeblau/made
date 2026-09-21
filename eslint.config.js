import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';

export default [
  {
    ignores: [
      '**/.astro/**',
      '**/.next/**',
      '**/.open-next/**',
      '**/cloudflare-env.d.ts',
      '**/next-env.d.ts',
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
