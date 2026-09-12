// Registers the DevLayout SessionStart hook in ~/.claude/settings.json.
//
// Done in Node rather than PowerShell on purpose: upstream's setup script does
// ConvertFrom-Json -AsHashtable | ConvertTo-Json, which (a) needs PowerShell 6+
// despite the script declaring #Requires -Version 5.1, and (b) rewrites and
// reformats the whole settings file. This edits only the one key it owns,
// appends the entry last, and is idempotent.

const fs = require('fs');
const path = require('path');

const settingsPath = path.join(process.env.USERPROFILE, '.claude', 'settings.json');
const hookPath = path.join(process.env.USERPROFILE, '.claude', 'hooks', 'devlayout-session-save.ps1');
const command =
  'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' +
  hookPath.replace(/\\/g, '/');

if (!fs.existsSync(settingsPath)) {
  console.error('settings.json not found: ' + settingsPath);
  process.exit(1);
}

// Back up before touching it.
const backup = settingsPath + '.bak-devlayout-' + Date.now();
fs.copyFileSync(settingsPath, backup);

const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
settings.hooks = settings.hooks || {};
settings.hooks.SessionStart = settings.hooks.SessionStart || [];

const already = settings.hooks.SessionStart.some(entry =>
  (entry.hooks || []).some(
    h => typeof h.command === 'string' && h.command.includes('devlayout-session-save')
  )
);

if (already) {
  fs.unlinkSync(backup);
  console.log('SessionStart hook already registered; nothing to do.');
  process.exit(0);
}

settings.hooks.SessionStart.push({
  hooks: [{ type: 'command', command: command, timeout: 5 }],
});

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n', 'utf8');

// Re-parse to prove the file is still valid before declaring success.
JSON.parse(fs.readFileSync(settingsPath, 'utf8'));

console.log('SessionStart hook registered (entry ' +
  settings.hooks.SessionStart.length + ' of ' + settings.hooks.SessionStart.length + ').');
console.log('Backup: ' + backup);
