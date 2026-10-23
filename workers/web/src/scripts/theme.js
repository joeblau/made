const STORAGE_KEY = 'made-theme';

export function normalizeTheme(value) {
  return value === 'light' || value === 'dark' ? value : null;
}

export function nextTheme(current) {
  return current === 'dark' ? 'light' : 'dark';
}

function storedTheme() {
  try {
    return normalizeTheme(window.localStorage.getItem(STORAGE_KEY));
  } catch {
    return null;
  }
}

export function initTheme() {
  const root = document.documentElement;
  const system = window.matchMedia('(prefers-color-scheme: dark)');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const toggles = [...document.querySelectorAll('[data-theme-toggle]')];
  const pictures = [...document.querySelectorAll('[data-theme-picture]')];
  const colors = [...document.querySelectorAll('meta[data-theme-color]')];
  let current = normalizeTheme(root.dataset.theme) ?? storedTheme() ?? (system.matches ? 'dark' : 'light');
  let transitioning = false;

  const apply = (theme, persist) => {
    current = theme;
    root.dataset.theme = theme;
    root.dataset.themeSource = persist ? 'user' : 'system';
    if (persist) {
      try { window.localStorage.setItem(STORAGE_KEY, theme); } catch { /* The theme still applies when storage or transitions are unavailable. */ }
    }
    for (const meta of colors) meta.media = meta.dataset.themeColor === theme ? 'all' : 'not all';
    for (const picture of pictures) {
      for (const source of picture.querySelectorAll('source[data-appearance]')) {
        source.media = source.dataset.appearance === theme ? 'all' : 'not all';
      }
    }
    const label = `Switch to ${nextTheme(theme)} theme`;
    for (const toggle of toggles) {
      toggle.setAttribute('aria-label', label);
      toggle.setAttribute('aria-pressed', String(theme === 'dark'));
      toggle.setAttribute('title', label);
      toggle.querySelector('[data-theme-label]')?.replaceChildren(label);
    }
  };

  apply(current, storedTheme() !== null);

  system.addEventListener('change', (event) => {
    if (storedTheme() === null) apply(event.matches ? 'dark' : 'light', false);
  });

  for (const toggle of toggles) {
    toggle.addEventListener('click', async () => {
      if (transitioning) return;
      const theme = nextTheme(current);
      if (reducedMotion.matches || typeof document.startViewTransition !== 'function') {
        apply(theme, true);
        return;
      }
      transitioning = true;
      const bounds = toggle.getBoundingClientRect();
      const x = bounds.left + bounds.width / 2;
      const y = bounds.top + bounds.height / 2;
      const radius = Math.hypot(Math.max(x, window.innerWidth - x), Math.max(y, window.innerHeight - y));
      const transition = document.startViewTransition(() => apply(theme, true));
      try {
        await transition.ready;
        root.animate(
          [
            { clipPath: `circle(0px at ${x}px ${y}px)` },
            { clipPath: `circle(${radius}px at ${x}px ${y}px)` },
          ],
          { duration: 620, easing: 'cubic-bezier(0.22, 1, 0.36, 1)', pseudoElement: '::view-transition-new(root)' },
        );
      } catch { /* The theme still applies when storage or transitions are unavailable. */ }
      try { await transition.finished; } catch { /* The theme still applies when storage or transitions are unavailable. */ }
      transitioning = false;
    });
  }
}
