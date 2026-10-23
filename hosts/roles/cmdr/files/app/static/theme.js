// Runs before the page paints, so a saved theme does not flash the other one.
try { const t = localStorage.getItem('cmdr.theme'); if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t; } catch (e) { /* storage unavailable: follow the system */ }
