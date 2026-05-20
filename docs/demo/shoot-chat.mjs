import { chromium } from 'playwright';

const PORT = process.env.PORT || '8799';
const OUT = process.env.OUT || new URL('../images/mc-chat.png', import.meta.url).pathname;

const now = Date.now();
const m = (mins) => new Date(now - mins * 60000).toISOString();

const convo = [
  { role: 'user', source: 'telegram', ts: m(14),
    body: "What's on my plate today, and did the Globex proposal go out?" },
  { role: 'assistant', source: 'telegram', ts: m(14), tokens: 1840, cost_usd: 0.012, duration_ms: 4200,
    body: "Morning. Three things need you today:\n\n1. **Globex proposal** — shipped 09:14, opened twice since. No reply yet.\n2. **Acme renewal** — awaiting your sign-off on the draft (in Drafts).\n3. **Northwind** — went quiet 8 days ago; want me to send the nudge?\n\nEverything else is on track." },
  { role: 'user', source: 'dashboard', ts: m(6),
    body: "Yes, send the Northwind nudge. Keep it short." },
  { role: 'assistant', source: 'dashboard', ts: m(6), tokens: 920, cost_usd: 0.006, duration_ms: 2600,
    body: "Done — drafted and sent a 3-line check-in referencing their Q2 timeline. Logged it as a commitment to follow up Thursday if there's no reply. I'll flag it in tomorrow's brief." },
  { role: 'user', source: 'voice', ts: m(2),
    body: "Great. Remind me to review the Acme draft after lunch." },
  { role: 'assistant', source: 'voice', ts: m(2), tokens: 410, cost_usd: 0.003, duration_ms: 1500,
    body: "Set a reminder for 1:30pm to review the Acme renewal draft. 🔔" },
];

const run = async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  await page.addInitScript(c => {
    localStorage.setItem('dashboard-chat-history', JSON.stringify(c));
  }, convo);
  await page.goto(`http://localhost:${PORT}/index.html`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(2000);
  await page.click('[data-action="nav"][data-tab="chat"]');
  await page.waitForTimeout(1200);
  await page.screenshot({ path: OUT, fullPage: true });
  console.log('re-shot: mc-chat.png with synthetic conversation');
  await browser.close();
};
run().catch(e => { console.error(e); process.exit(1); });
