(() => {
  const root = document.documentElement;
  let stored = null;
  try {
    const value = window.localStorage.getItem('made-theme');
    if (value === 'light' || value === 'dark') stored = value;
  } catch {
    stored = null;
  }
  const theme = stored ?? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  root.dataset.theme = theme;
  root.dataset.themeSource = stored ? 'user' : 'system';
  for (const meta of document.querySelectorAll('meta[data-theme-color]')) {
    meta.media = meta.dataset.themeColor === theme ? 'all' : 'not all';
  }
})();
