// Lightweight webhook receiver — accepts POSTs from GHL and Gmail,
// routes to the relevant Discord channel via discord-memory.sh
const http = require('http');
const { execSync } = require('child_process');

const PORT = 8090;
const DISCORD = '{{TENANT_AGENT_HOME}}/scripts/discord-memory.sh';

function discordNotify({ channel, title, text, color }) {
  try {
    const safeTitle = (title || '').replace(/"/g, '\\"').replace(/`/g, '\\`');
    const safeText  = (text  || '').replace(/"/g, '\\"').replace(/`/g, '\\`');
    const colorArg  = color ? `--color ${color}` : '';
    execSync(
      `bash "${DISCORD}" notify --channel "${channel}" --title "${safeTitle}" --text "${safeText}" ${colorArg}`,
      { timeout: 10000, stdio: 'ignore' }
    );
  } catch (e) {
    console.error('discord notify error:', e.message);
  }
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => { body += chunk; if (body.length > 50000) reject(new Error('too large')); });
    req.on('end', () => {
      try { resolve(JSON.parse(body)); } catch { resolve({}); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method !== 'POST') { res.writeHead(405); res.end(); return; }

  let body;
  try { body = await parseBody(req); } catch { res.writeHead(400); res.end(); return; }

  const url = req.url.split('?')[0];

  // --- GHL webhook ---
  if (url === '/webhook/ghl') {
    const event = body.type || body.event || 'unknown';
    const contact = body.contact?.name || body.firstName || '';
    const pipeline = body.pipeline?.name || '';
    const stage = body.pipelineStage?.name || body.stage || '';
    const amount = body.monetaryValue ? `$${body.monetaryValue}` : '';

    let title = `GHL — ${event.replace(/_/g, ' ')}`;
    let text = '';
    if (contact) text += `**Contact:** ${contact}\n`;
    if (pipeline) text += `**Pipeline:** ${pipeline}\n`;
    if (stage)    text += `**Stage:** ${stage}\n`;
    if (amount)   text += `**Value:** ${amount}\n`;
    if (!text)    text = JSON.stringify(body).slice(0, 400);

    discordNotify({ channel: 'ghl-activity', title, text, color: 3066993 });
    res.writeHead(200); res.end('ok');
    return;
  }

  // --- Gmail / email triage alert ---
  if (url === '/webhook/gmail') {
    const sender  = body.from || body.sender || '';
    const subject = body.subject || '';
    const snippet = body.snippet || body.preview || '';
    const priority = body.priority || '';

    const title = `${priority ? `[${priority}] ` : ''}Email — ${sender}`;
    const text  = `**Subject:** ${subject}\n${snippet ? `\n${snippet.slice(0, 300)}` : ''}`;
    const color = priority === 'HIGH' ? 15158332 : 9807270;

    discordNotify({ channel: 'gmail-alerts', title, text, color });
    res.writeHead(200); res.end('ok');
    return;
  }

  // --- Generic agent event ---
  if (url === '/webhook/agent') {
    const title = body.title || 'Agent event';
    const text  = body.text  || JSON.stringify(body).slice(0, 400);
    const ch    = body.channel || 'agent-log';
    discordNotify({ channel: ch, title, text });
    res.writeHead(200); res.end('ok');
    return;
  }

  res.writeHead(404); res.end();
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Discord webhook receiver listening on 127.0.0.1:${PORT}`);
});
