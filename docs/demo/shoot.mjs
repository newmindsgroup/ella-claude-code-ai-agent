import { chromium } from 'playwright';
import { fileURLToPath } from 'url';
import path from 'path';

const PORT = process.env.PORT || '8799';
const OUT = process.env.OUT || new URL('../images', import.meta.url).pathname;

const TABS = [
  'overview','tasks','goals','memory','drafts','inbound','improvements',
  'insights','skills','audit','rules','deploys','activity','roi','drift',
  'competitive','schedule','telemetry','chat','settings'
];

const run = async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 2,
  });
  const page = await ctx.newPage();

  const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });

  await page.goto(`http://localhost:${PORT}/index.html`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(2500); // let hydrate() finish

  for (const tab of TABS) {
    try {
      await page.click(`[data-action="nav"][data-tab="${tab}"]`, { timeout: 5000 });
    } catch (e) {
      // some tabs might be reachable only by hash; try a JS nav fallback
      await page.evaluate(t => {
        const el = document.querySelector(`[data-tab="${t}"]`);
        if (el) el.click();
      }, tab);
    }
    await page.waitForTimeout(1200);
    const file = path.join(OUT, `mc-${tab}.png`);
    await page.screenshot({ path: file, fullPage: true });
    console.log(`shot: mc-${tab}.png`);
  }

  await browser.close();
  if (errors.length) {
    console.log(`\n--- ${errors.length} console errors (first 10) ---`);
    errors.slice(0, 10).forEach(e => console.log('  ' + e.slice(0, 160)));
  }
};

run().catch(e => { console.error(e); process.exit(1); });
