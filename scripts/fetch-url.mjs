// 通用下载器：跟随重定向，写到 argv[2]
import https from "node:https";
import { createWriteStream, statSync } from "node:fs";

const url = process.argv[2];
const out = process.argv[3];

function go(u, left) {
  const parsed = new URL(u);
  https
    .get(
      {
        host: parsed.host,
        path: parsed.pathname + parsed.search,
        headers: { "user-agent": "Mozilla/5.0", accept: "*/*" },
      },
      (r) => {
        if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location && left > 0) {
          r.resume();
          return go(new URL(r.headers.location, u).toString(), left - 1);
        }
        if (r.statusCode !== 200) {
          console.log(`  FAILED ${r.statusCode} ${u}`);
          r.resume();
          return;
        }
        let n = 0;
        const t0 = Date.now();
        const o = createWriteStream(out);
        r.on("data", (c) => (n += c.length));
        r.pipe(o);
        o.on("finish", () => {
          console.log(`  saved ${n} B in ${Date.now() - t0}ms -> ${out}`);
        });
      },
    )
    .on("error", (e) => console.log(`  ERR ${e.code} ${u}`));
}

go(url, 6);
