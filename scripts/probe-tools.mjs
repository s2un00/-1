// Probe: does the Hindsight dsh entry actually register its tools for a given cwd?
// Usage: node probe-tools.mjs <dir>
const dir = process.argv[2] ?? process.cwd();
process.chdir(dir);

const registered = [];

const mod = await import(
  'file:///C:/Users/Administrator/.dsh/profiles/desktop/node_modules/@vectorize-io/hindsight-coding-agents/dist/dsh.js'
);

let injectCalled = false;
const ctx = {
  on() {},
  inject(deps, cb) {
    injectCalled = true;
    cb({
      tools: {
        register(t) { registered.push(t.name); },
        schemas() { return []; }
      }
    });
  }
};

let err = null;
try {
  mod.apply(ctx);
} catch (e) {
  err = String(e && e.stack ? e.stack : e);
}

console.log(JSON.stringify({
  cwd: dir,
  injectCalled,
  count: registered.length,
  tools: registered,
  error: err
}, null, 2));
