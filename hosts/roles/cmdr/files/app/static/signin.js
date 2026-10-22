(() => {
  'use strict';
  // The sign-in happens in another tab and sets the session cookie for this site; as soon as the cookie works here, load the real page.
  const check = async () => {
    try {
      const r = await fetch('/api/me', { credentials: 'same-origin', cache: 'no-store' });
      if (r.ok) location.reload();
    } catch (e) { /* offline or restarting: try again */ }
  };
  setInterval(check, 2000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) check(); });
})();
