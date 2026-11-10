/* Style gate. Errors fail the build; the legacy literal-colour count is held to a
   recorded baseline so the debt cannot grow while it is being paid down. */
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const baseline = JSON.parse(readFileSync('scripts/css-baseline.json', 'utf8'));
const errors = [];
const warnings = [];
const cssFiles = readdirSync('static/css').filter((f) => f.endsWith('.css'));
const stripRoot = (s) => s.replace(/:root\s*\{[^}]*\}/g, '');

for (const f of cssFiles) {
  const raw = readFileSync(join('static/css', f), 'utf8');
  const body = stripRoot(raw);
  const open = (raw.match(/\{/g) || []).length;
  const close = (raw.match(/\}/g) || []).length;
  if (open !== close) errors.push(`${f}: unbalanced braces (${open} open, ${close} close)`);

  const lits = (body.match(/#[0-9a-fA-F]{3,8}\b/g) || []).length + (body.match(/rgba?\(\s*\d/g) || []).length;
  const allowed = baseline[f]?.literals ?? 0;
  if (lits > allowed) errors.push(`${f}: ${lits} literal colours outside :root, baseline ${allowed}`);
  else if (lits < allowed) warnings.push(`${f}: ${lits} literal colours (baseline ${allowed}) — lower the baseline`);

  const vw = (body.match(/\b100vw\b/g) || []).length;
  const vwAllowed = baseline[f]?.vw ?? 0;
  if (vw > vwAllowed) errors.push(`${f}: ${vw} use(s) of 100vw, baseline ${vwAllowed} — html/body carry overflow-x: clip, but new uses overflow`);

  const all = (body.match(/transition\s*:\s*all\b/g) || []).length;
  if (all) warnings.push(`${f}: ${all} "transition: all"`);
}

for (const f of readdirSync('templates').filter((f) => f.endsWith('.html'))) {
  const html = readFileSync(join('templates', f), 'utf8');
  for (const m of html.matchAll(/\/static\/css\/([\w.-]+\.css)(\?v=[^"']+)?/g)) {
    if (!m[2]) errors.push(`templates/${f}: ${m[1]} loaded without a version pin`);
  }
}

for (const w of warnings) console.log('warn ' + w);
for (const e of errors) console.log('FAIL ' + e);
console.log(`\n${cssFiles.length} stylesheets, ${errors.length} error(s), ${warnings.length} warning(s)`);
if (errors.length) process.exit(1);
console.log('style checks passed');
