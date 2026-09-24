// Lint do frontend (JS de navegador), executado a partir de ../frontend.
const js = require('@eslint/js');
const globals = require('globals');

module.exports = [
  js.configs.recommended,
  { files: ['**/*.js'], languageOptions: { sourceType: 'script', globals: globals.browser } },
];
