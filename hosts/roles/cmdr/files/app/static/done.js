(() => {
  'use strict';
  // Runs in the window that just finished signing in. Tell the waiting page (a frame in the console) at once, count down, then close;
  // a window the browser will not let a script close (opened as a plain tab) falls back to going to the page itself.
  const SECONDS = 3;
  try { const c = new BroadcastChannel('cmdr-auth'); c.postMessage('signed-in'); setTimeout(() => c.close(), 500); } catch (e) { /* the frame polls as well */ }
  const n = document.getElementById('n');
  const ring = document.getElementById('ring');
  const msg = document.getElementById('msg');
  let left = SECONDS;
  ring.classList.add('run');
  const t = setInterval(() => {
    left -= 1;
    n.textContent = String(Math.max(left, 0));
    if (left > 0) return;
    clearInterval(t);
    window.close();
    // Still here a moment later: the browser kept the window open.
    setTimeout(() => {
      msg.textContent = 'You can close this window now, or open cmdr here.';
      n.textContent = '✓';
    }, 400);
  }, 1000);
})();
