import { afterLoadAndIdle } from './cockpit-loader.js';
import { initQrDownload } from './qr-download.js';
import { initTheme } from './theme.js';

export function initSite() {
  initTheme();
  initQrDownload();
  afterLoadAndIdle(window)
    .then(() => import('./interactions.js'))
    .then(({ initInteractions }) => initInteractions())
    .catch((error) => console.warn('Optional page interactions unavailable', error));
}
