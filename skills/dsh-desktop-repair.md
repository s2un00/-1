---
name: dsh-desktop-repair
description: Diagnose and repair DeepSeek Harness (dsh) desktop app startup crashes — especially "Unexpected token '', ... is not valid JSON" (UTF-8 BOM in a profile package.json) and "YAMLException: bad indentation of a mapping entry" (corrupted cordis.patch.yml overlay). Use when the DeepSeek Harness / dsh desktop app shows "The application could not start or stopped unexpectedly", when a crash-*-host.log appears under %APPDATA%\@deepseek-ai\dsh-desktop\logs, or when dsh profile config looks corrupted or was reset to defaults.
agent_created: true
---

# DeepSeek Harness (dsh) Desktop Startup Repair

The dsh desktop app spawns an internal **host** process at startup. If the host
throws, the shell stays up but shows *"The application could not start or stopped
unexpectedly"* and writes a `crash-<ts>-host.log`. Most such crashes are caused by
a **corrupted profile config file**, not by a damaged install — do NOT reinstall
first, and do NOT touch the `tasks`/sessions data.

## Key paths (Windows)

| What | Path |
|---|---|
| App exe | `%LOCALAPPDATA%\Programs\DeepSeek Harness\DeepSeek Harness.exe` |
| App data | `%APPDATA%\@deepseek-ai\dsh-desktop` |
| Crash logs | `%APPDATA%\@deepseek-ai\dsh-desktop\logs\crash-*-host.log` |
| Profile root | `%USERPROFILE%\.dsh` |
| Profile config | `%USERPROFILE%\.dsh\profiles\<profile>\package.json` |
| Profile overlay | `%USERPROFILE%\.dsh\profiles\<profile>\cordis.patch.yml` |
| App's own pre-change snapshot | `%USERPROFILE%\.dsh\profiles\<profile>\.hsg-backup\` |

macOS equivalents: app under `/Applications`, data under `~/Library/Application Support/@deepseek-ai/dsh-desktop`, profile at `~/.dsh`.

## Root causes + fixes

### 1. UTF-8 BOM in `package.json` (most common)
Symptom in log:
```
DesktopHostFatalError: Unexpected token '', "{ ... is not valid JSON
  at JSON.parse
  at readProfileManifest (.../dsh-app-boot/lib/index.js)
  at loadProfileDirectory (...)
```
Cause: a config/plugin writer rewrote `package.json` with a Windows-style
UTF-8 BOM (`ef bb bf`). `JSON.parse` rejects the leading U+FEFF.
Fix: **strip the 3-byte BOM**, keep the rest byte-identical. The JSON itself is valid.

### 2. Bad YAML indentation in `cordis.patch.yml`
Symptom:
```
dsh: failed to parse overlay ...\cordis.patch.yml:
YAMLException: bad indentation of a mapping entry (LINE:COL)
  at parsePatchList
  at loadOverlayPatches
  at loadProfileDirectory
```
Cause: same buggy writer mangled indentation of the last appended entry
(e.g. `    disabled: false` with 4 spaces where 2 are expected).
Fix: correct the indentation (sibling keys under a `- id:` list item use 2 spaces).

### Note: the app self-heals by wiping the overlay
When an overlay fails to parse, dsh may **reset `cordis.patch.yml` to the empty
template `[]`**, silently discarding the user's theme / pet / model / plugin
overrides. Recover them from `.hsg-backup\cordis.patch.yml.<ts>` (valid, no BOM),
re-applying any single line the buggy writer mangled.

## Procedure

1. **Read the newest crash log** — it names the failing file and function. Don't guess.
2. **Scan for BOM** — first 3 bytes == `ef bb bf`:
   `head -c 3 FILE | xxd` (Linux/Git-Bash) or check `charCodeAt(0) === 0xfeff`.
3. **Validate authoritatively** with the profile's own bundled `js-yaml`:
   `NODE_PATH="<profile>/node_modules" node -e "require('js-yaml').load(require('fs').readFileSync(p,'utf8'))"`
   (js-yaml is what the host uses, so its verdict matches the app.)
4. **Always back up before editing** into `~/.dsh/.bom-fix-backup/<timestamp>/`.
5. **Close the app before editing** so it can't clobber the file on shutdown:
   `taskkill //F //IM "DeepSeek Harness.exe"`
6. **Relaunch and verify** (see below).

## Verification
- App process count > 0: `tasklist //FI "IMAGENAME eq DeepSeek Harness.exe"`
- The host listens on a `127.0.0.1:<port>` socket; probing returns
  `HTTP 401` + `dsh web authentication required` — **401 is healthy** (it needs
  the in-app token). `000`/refused = host is dead.
- **No new `crash-*-host.log`** after relaunch (compare the file count).

## Pitfalls
- The single quotes in `Unexpected token ''` are the BOM itself — do not hunt for a stray comma.
- Do not "fix" by deleting the profile or reinstalling; that loses the user's settings.
- After a `[]` self-heal, the app *looks* fine but the user's config is gone — check `.hsg-backup`.
- Git-Bash mangles Windows-style paths inside `node -e "... $VAR ..."`; use a script file for paths.

See `scripts/repair.py` for a ready-made, backup-first repair that fixes both cases.
