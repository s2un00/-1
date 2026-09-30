# Hindsight 本地长期记忆栈（Windows / DeepSeek Harness）

给 dsh（DeepSeek Harness）桌面版接上一个**跑在自己机器上**的长期记忆后端：
会话里自动注入项目记忆，并对外暴露 8 个 `hindsight_*` 工具让 Agent 主动查/写。

本仓库是这台机器上把这套东西**装通、修好、并踩完所有坑**之后的整理产物 ——
包括可复用的启动脚本、可复现的排障手册，以及一份事故复盘。

> 没有任何密钥。所有凭据都是占位符，见 [安全说明](#安全说明)。

---

## 架构

```
   dsh 桌面版（Electron）
        │  ~/.dsh/profiles/desktop/package.json   ← 插件必须同时出现在
        │  ~/.dsh/profiles/desktop/cordis.patch.yml   dependencies + bundles + patch 行
        ▼
   @vectorize-io/hindsight-coding-agents  (dist/dsh.js)
        │  · agent/session-start / pre-step  →  记忆注入（↳ memory bank "coding-agent::<repo>"）
        │  · tools.register × 8              →  hindsight_* 工具进工具表
        ▼
   Hindsight daemon  http://127.0.0.1:9077        ← hindsight-embed -p coding-agent daemon start
        │  向量化 ONNX(bge-small-en-v1.5) / 重排 flashrank / 抽取 LLM=DeepSeek
        ▼
   PostgreSQL  127.0.0.1:5433   (pgdata3, 扩展: vector + pg_trgm)
```

两个进程都必须活着：**Postgres 在 5433，daemon 在 9077**。没人会自动帮你起 Postgres。

## 快速开始

```powershell
# 1) 起记忆栈（Postgres + daemon），脚本自带自愈循环
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\keep-stack3.ps1

# 2) 验证（注意 --noproxy：本机 curl 会继承系统代理，否则得到假的 502）
curl -s --noproxy '*' http://127.0.0.1:9077/health
# {"status":"healthy","database":"connected", ...}

# 3) 看记忆银行
curl -s --noproxy '*' http://127.0.0.1:9077/v1/default/banks
# {"banks":[{"bank_id":"coding-agent::<repo>", ...}], ...}
```

> `keep-stack3.ps1` 跑在**后台作业**里，但 daemon 是**经 WMI 在作业之外启动**的
> （`Invoke-CimMethod Win32_Process Create`；WMI provider 在服务宿主 `WmiPrvSE.exe` 里，不是作业成员）。
> 所以**作业被回收也不会带走 daemon** —— 这条是 2026-09-30 16:51 实测过的。
> 它会：清代理变量 → 起 Postgres(5433) → 建扩展 → 起 daemon → 每 15 秒巡检自愈。
> 日志：`keep-stack3.log`。冷启动约 25 秒到健康。
>
> 为什么不直接"detach"：`DETACHED_PROCESS`/`detached()` 只脱离控制台、不脱离作业；
> 唯一的设计逃逸口 `CREATE_BREAKAWAY_FROM_JOB` 在本机被拒（WinError 5，作业没开
> `JOB_OBJECT_LIMIT_BREAKAWAY_OK`）。细节和实测证据见 `docs/01-status-and-restart.md`。

登录自启：把 `scripts/startup-hindsight-memory-stack.vbs` 放进
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`（由 Explorer 在作业对象之外拉起）。

## 文件地图

| 路径 | 说明 |
|---|---|
| `scripts/keep-stack3.ps1` | **主脚本**：常驻监督 Postgres + daemon，挂了自动重启 |
| `scripts/start-memory-stack.cmd` | 自启/手动启动用的 cmd 包装（纯 ASCII） |
| `scripts/startup-hindsight-memory-stack.vbs` | 放进 Startup 文件夹的隐藏启动器 |
| `scripts/restart-stack.ps1` | 全量环境变量版启动脚本（排障参考） |
| `scripts/fix-dsh-plugin-manifest.mjs` | 修 dsh profile 里丢失的插件启用痕迹（带自校验） |
| `scripts/probe-tools.mjs` | 探针：证明插件能否注册 `hindsight_*` 工具 |
| `scripts/fetch-url.mjs` | 通用下载器（本机 .NET TLS 坏，一律走 node fetch） |
| `scripts/spawn-breakaway.py` | **反面记录**：`CREATE_BREAKAWAY_FROM_JOB` 逃逸作业，本机被拒（WinError 5），已弃用 |
| `docs/01-status-and-restart.md` | 现状、启动步骤、已落盘配置 |
| `docs/02-handoff-notes.md` | 会话交接备忘（含全部踩过的坑） |
| `docs/03-local-memory-repair-log.md` | 把云端模式改成本地 daemon 的完整记录 |
| `docs/04-external-resources.md` | 外部资料/依赖清单 |
| `docs/05-postmortem.html` | 事故复盘（罪状清单 + 根因 + 家规） |
| `skills/*.md` | 两个可复用技能：记忆栈运维、dsh 桌面版修复 |
| `config/*.example` | 配置模板（全部脱敏） |

## 排障速查

| 症状 / 报错 | 真因 | 处理 |
|---|---|---|
| `Start-Process : 已添加项。字典中的关键字:"http_proxy"所添加的关键字:"HTTP_PROXY"` | 父环境里同一变量有大小写两个变体，该 cmdlet 重建的是**大小写敏感**字典 | 用 `[Diagnostics.Process]::Start` + `EnvironmentVariables.Clear()` 后重建单大小写环境（见 keep-stack3.ps1） |
| `& .\x.ps1` → `未对文件进行数字签名` | 执行策略 | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File x.ps1` |
| daemon：`Failed to start embedded PostgreSQL … IO error: (os error 5)` | daemon 去起了**自带嵌入式** PG（沙箱挡全局共享内存，必挂） | 先让外部 5433 起来，daemon 就会连外部库 |
| daemon：`RuntimeError: Database migration failed` | 外部 PG **没起**（迁移在启动时跑） | 去把 Postgres 起起来，**不要**改 DB URL |
| `curl http://127.0.0.1:9077/health` → `502 upstream connect failed` | curl 继承了系统代理 | 加 `--noproxy '*'` |
| 有注入横幅、但工具表没有 `hindsight_*` | profile 的**启用痕迹**丢了：插件只在 `bundles` 里，不在 `dependencies`；`cordis.patch.yml` 没有 `- id: hindsight` 行 | 跑 `fix-dsh-plugin-manifest.mjs`，然后**重启桌面版** |
| 桌面版起不来，`YAMLException: bad indentation (90:13)` | 手写 `cordis.patch.yml` 缩进错了（应为 2 空格） | 用 YAML parser 校验后再重启；应用解析失败会**静默重置**该文件 |

权威日志位置：

- 插件诊断：`~/.hindsight/coding-agents-logs/diag.jsonl`（`inject_ok` / `pages_failed` / `retain_failed`）
- 插件日志：`~/.hindsight/coding-agents-logs/plugin.log`（含 `↳ memory bank "…"` 横幅）
- 插件开关历史：`~/.dsh/profiles/<profile>/.dsh-market/log.ndjson`（谁启用/禁用了什么）
- 桌面版崩溃：`%APPDATA%\@deepseek-ai\dsh-desktop\logs\crash-*-host.log`

## 安全说明

- **仓库内不含任何真实密钥。** 原脚本里硬编码的 LLM API key 已替换为
  `$env:DEEPSEEK_API_KEY`（PowerShell）或 `your-deepseek-api-key-here`（配置模板）。
  运行前请自行通过环境变量或 `~/.hindsight/profiles/<profile>.env` 提供。
- `postgresql://hindsight:hindsight@127.0.0.1:5433/…` 中的口令是**本机开发用默认值**，
  仅监听 `127.0.0.1`，不要暴露到网络，也不要复用到别处。
- 本仓库所有端口都只绑定回环地址。

## 已知限制

- ~~后台作业顶住的存活方式只是会话级~~ **已解决（2026-09-30 16:51）**：daemon 改由 WMI 在作业外启动，
  杀掉作业后实测 health 连续 64 秒 UP、PID 不变。仍建议把它当**可随时重跑**的东西：
  探到 `health` 失败就直接再跑一次 `keep-stack3.ps1` 或双击 `start-memory.cmd`。
- WMI 子进程不继承调用者环境，只拿到持久化的用户环境；因此启动命令必须显式
  `set "USERPROFILE=…"`，否则 daemon 会去找 C: 的 profile 目录并死在 `PermissionError 13`。
- 脚本里的绝对路径按本机布局（`F:\deepseek\...`）写死，换机器需要替换。
- 嵌入式 PostgreSQL（`pg0://`）在受限令牌/沙箱环境下起不来，本方案刻意绕开它，走外部 PG。

## 许可

内部排障资料，按原样提供，无担保。
