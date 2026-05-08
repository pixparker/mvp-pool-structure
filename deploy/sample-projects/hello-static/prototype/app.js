// Render the build metadata baked into the image at /version.txt by the
// static template's Dockerfile. Reading this file (rather than baking the
// values into the HTML) means a redeploy is reflected without rebuilding
// the index.html — though the COPY in Dockerfile pulls index.html each
// build anyway, so this is mainly to demo the /version.txt convention.
(async () => {
  const $ = (id) => document.getElementById(id);
  $('ua').textContent = navigator.userAgent;
  try {
    const res = await fetch('./version.txt', { cache: 'no-store' });
    if (!res.ok) throw new Error(res.status);
    const text = await res.text();
    const kv = Object.fromEntries(
      text
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean)
        .map((l) => {
          const i = l.indexOf('=');
          return i < 0 ? [l, ''] : [l.slice(0, i), l.slice(i + 1)];
        })
    );
    $('tag').textContent = kv.tag || 'unknown';
    $('built').textContent = kv.build_time || 'unknown';
    $('cache').textContent = kv.cache_mode || 'unknown';
  } catch (e) {
    $('tag').textContent = '/version.txt unavailable';
    $('built').textContent = '—';
    $('cache').textContent = '—';
  }
})();
