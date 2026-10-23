(() => {
  'use strict';
  // The identity provider refuses to be framed, so sign-in runs in a small window of its own. It sets the session cookie for this site; as soon
  // as the cookie works here, load the real page. The window announces itself on a BroadcastChannel when it is done, so this is near-instant.
  const go = document.getElementById('go');
  const note = document.getElementById('note');
  let win = null;
  go.addEventListener('click', (e) => {
    // Opened by script, the window may close itself afterwards; if the browser blocks the pop-up the plain link still works (new tab).
    try {
      win = window.open(go.href, 'cmdr-signin', 'popup,noopener,width=560,height=760');
      if (win) { e.preventDefault(); }
    } catch (err) { /* fall back to the link */ }
    note.textContent = 'Waiting for sign-in…';
  });
  const check = async () => {
    try {
      const r = await fetch('/api/me', { credentials: 'same-origin', cache: 'no-store' });
      if (r.ok) location.reload();
    } catch (e) { /* offline or restarting: try again */ }
  };
  try { new BroadcastChannel('cmdr-auth').onmessage = check; } catch (e) { /* older browser: polling below covers it */ }
  setInterval(check, 2000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) check(); });
})();
