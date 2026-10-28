(() => {
  'use strict';
  // Runs in the window that just finished signing in. Tell the waiting page (a frame in the console) at once, count down, then close.
  // The button closes the window too; a window the browser will not let a script close (opened as a plain tab) says so and is left alone.
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
    closeNow();
  }, 1000);
  function closeNow() {
    window.close();
    // Still here a moment later: the browser kept the window open.
    setTimeout(() => {
      msg.textContent = 'Your browser kept this window open. Close it yourself (Ctrl/Cmd+W); you are signed in.';
      n.textContent = '✓';
    }, 400);
  }
  document.getElementById('close').addEventListener('click', () => { clearInterval(t); closeNow(); });
})();
