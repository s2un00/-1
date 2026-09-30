// Restore the two things the plugin-manager enable action writes, which were lost
// when cordis.patch.yml was restored after the YAML-indentation crash:
//   1. "@vectorize-io/hindsight-coding-agents" in profile package.json dependencies
//   2. "- id: hindsight / disabled: false" row in profile cordis.patch.yml
// Backs both files up first, then re-parses each to prove it is still valid.
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire('file:///C:/Users/Administrator/.dsh/profiles/desktop/');
const yaml = require('js-yaml');

const PROFILE = 'C:\\Users\\Administrator\\.dsh\\profiles\\desktop';
const PKG = PROFILE + '\\package.json';
const PATCH = PROFILE + '\\cordis.patch.yml';
const PLUGIN = '@vectorize-io/hindsight-coding-agents';
const VERSION = '0.8.0';

const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
const BACKUP = 'F:\\deepseek\\.hindsight-setup\\dsh-plugin-fix-backup-' + stamp;
mkdirSync(BACKUP, { recursive: true });
copyFileSync(PKG, BACKUP + '\\package.json');
copyFileSync(PATCH, BACKUP + '\\cordis.patch.yml');
console.log('backup ->', BACKUP);

const report = { packageJson: {}, patchYml: {} };

// ---------- 1. package.json ----------
{
  const raw = readFileSync(PKG, 'utf8');
  report.packageJson.hadBom = raw.charCodeAt(0) === 0xfeff;
  const json = JSON.parse(raw.replace(/^\uFEFF/, ''));
  report.packageJson.inDepsBefore = Boolean(json.dependencies?.[PLUGIN]);
  report.packageJson.inBundles = Boolean(json.dsh?.profile?.bundles?.includes(PLUGIN));

  if (!json.dependencies) json.dependencies = {};
  json.dependencies[PLUGIN] = VERSION;

  const out = JSON.stringify(json, null, 2) + '\n';
  JSON.parse(out);                     // must re-parse
  writeFileSync(PKG, out, { encoding: 'utf8' });   // utf8, no BOM

  const check = JSON.parse(readFileSync(PKG, 'utf8'));
  report.packageJson.inDepsAfter = check.dependencies[PLUGIN];
  report.packageJson.stillInBundles = check.dsh.profile.bundles.includes(PLUGIN);
  report.packageJson.otherDeps = Object.keys(check.dependencies).length;
}

// ---------- 2. cordis.patch.yml ----------
{
  const raw = readFileSync(PATCH, 'utf8');
  report.patchYml.hadBom = raw.charCodeAt(0) === 0xfeff;
  const before = yaml.load(raw);       // throws if the current file is broken
  report.patchYml.entriesBefore = before.length;
  report.patchYml.alreadyHasHindsight = before.some((e) => e && e.id === 'hindsight');

  let text = raw;
  if (!text.endsWith('\n')) text += '\n';
  if (!report.patchYml.alreadyHasHindsight) {
    // exactly what the plugin manager writes when you enable the plugin, but with
    // 2-space indentation (the crash was `disabled:` indented 4 spaces -> YAMLException 90:13)
    text += '- id: hindsight\n  disabled: false\n';
  }
  writeFileSync(PATCH, text, { encoding: 'utf8' });

  const after = yaml.load(readFileSync(PATCH, 'utf8'));   // must still parse
  report.patchYml.entriesAfter = after.length;
  report.patchYml.hindsightRow = after.find((e) => e && e.id === 'hindsight') ?? null;
}

console.log(JSON.stringify(report, null, 2));
