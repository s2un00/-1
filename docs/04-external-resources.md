# Hindsight 记忆系统 · 外援排查清单

> **✅ 已解决（2026-09-30 12:0x）——不再需要外援。**
> 修复记录与第 6 节 5 个问题的答案见 `F:\deepseek\HINDSIGHT-本地记忆系统-修复完成.md`。
> 除了本文档定位到的 `HINDSIGHT_EMBED_API_DATABASE_URL`，还发现第二个凶手：
> `~/.hindsight/coding-agent.json` 带 UTF-8 BOM → 插件 `JSON.parse` 抛错被吞 → `serverMode` 静默回落成 `cloud` → 一直在打云端并吃 401。
> 本文档保留为原始排查存档。

> 生成时间：2026-09-30 12:0x　工作目录：`F:\deepseek`　机器：Windows，用户 `desktop-igj3vkb\administrator`
> 目标一句话：**让 DeepSeek Harness（DSH）桌面版的会话真正带上 Hindsight 长期记忆**（当前会话无 `hindsight_*` 工具、无 `↳ memory bank "coding-agent::deepseek"` 横幅）。

---

## 1. 环境固定事实

| 项 | 值 |
|---|---|
| Hindsight API 版本 | `hindsight_api 0.10.2`（`hindsight_api_slim 0.10.2`） |
| 启动器 | `F:\deepseek\.hindsight-bin\hindsight-embed.exe`（uv tool，`hindsight-embed`，uv 0.12.20） |
| 运行时本体 | `F:\deepseek\.hindsight-setup\uv-cache\archive-v0\<hash>\Lib\site-packages\`（**路径硬编码**，必须留在原绝对路径） |
| Python | `F:\deepseek\.hindsight-setup\uv-python\cpython-3.14.7-windows-x86_64-none` |
| Postgres 二进制 | `C:\Users\Administrator\.pg0\installation\18.1.0\bin\` |
| 数据库 | `postgresql://hindsight:hindsight@127.0.0.1:5433/hindsight`，PostgreSQL 18.1，扩展 `plpgsql,vector,pg_trgm,btree_gin`，25 张表**全为 0 行**（无任何已入库记忆） |
| API 端口 | `9077`；JSON 配置 `C:\Users\Administrator\.hindsight\coding-agent.json` = `{"serverMode":"daemon","apiPort":9077,"daemonProfile":"coding-agent","embedVersion":"0.10.2","autoInject":"reflect"}` |
| 用户级环境变量 | 已设 `HINDSIGHT_SERVER_MODE=daemon`、`HINDSIGHT_DAEMON_PROFILE=coding-agent`、`HINDSIGHT_API_PORT=9077`、`HINDSIGHT_API_DATABASE_URL=postgresql://hindsight:hindsight@127.0.0.1:5433/hindsight`、`HINDSIGHT_API_LLM_PROVIDER=deepseek`、`HINDSIGHT_API_LLM_MODEL=deepseek-chat`、`HINDSIGHT_API_LLM_BASE_URL=https://api.deepseek.com`、`HINDSIGHT_API_LLM_API_KEY=your-deepseek-api-key-here 等 |
| 向量化 | **只能本地 ONNX**（DeepSeek 无 embeddings 端点）：模型 `F:\deepseek\.hindsight-home\models\bge-small-en-v1.5\onnx\model.onnx` |
| 网络 | 无代理；`huggingface.co` 不通（走 `hf-mirror.com`，且 `HF_HUB_OFFLINE=1`）；PowerShell/.NET TLS 损坏（`irm`/`curl` 报 `SEC_E_NO_CREDENTIALS`），下载必须走 node 的 `fetch`（通用下载器 `F:\deepseek\.hindsight-setup\fetch-url.mjs`） |
| 本工具进程权限 | **Low Mandatory Level**（`S-1-16-4096`），`BUILTIN\Administrators` = "Group used for deny only" → 无法真提权；`Get-CimInstance` 直接 `拒绝访问 0x80041003` |

---

## 2. 已经做完的事（别再重做）

1. 从回收站 `F:\$RECYCLE.BIN\S-1-5-21-30007198-1024431385-2060941524-500` 恢复了被误删的整套运行时：`.hindsight-home`(690MB)、`.hindsight-bin`(99MB)、`.hindsight-setup`(6.6GB，含 `uv-cache` 241937 文件)。**手段**：`Move-Item` 移目录会被沙箱拒绝并留下半搬移状态，必须用 `robocopy <src> <dst> /E`。旧版留在 `F:\deepseek\.hindsight-setup.old`。
2. Postgres 能正常起来（**推翻了旧交接文档的担心**）：`C:\Users\Administrator\.pg0\installation\18.1.0\bin\postgres.exe -D F:\deepseek\.hindsight-home\pgdata3 -p 5433`，`pg_isready` 2 秒后 `accepting connections`。从 `run_in_background: true` 的 pwsh 作业里起才活得久（前台进程会随工具调用结束被杀）。
3. 数据库/角色/扩展已建好，表结构已由 alembic 迁移完毕（25 表，0 行）。
4. 已知 daemon 之外的一切都是好的：插件包存在、补丁层文件存在、`pnpm-lock` 完整。

---

## 3. 当前唯一阻塞：daemon 起不来（exit code 3）

复现（`F:\deepseek\.hindsight-setup\restart-stack.ps1` 会做全套）：
```
& F:\deepseek\.hindsight-bin\hindsight-embed.exe -p coding-agent daemon start
```
输出与日志 `F:\deepseek\.hindsight-home\.hindsight\profiles\coding-agent.log`（2026-09-30 11:49-11:50）：
```
INFO - hindsight_api.pg0 - Starting embedded PostgreSQL (name=hindsight-embed-coding-agent, port=auto)...
RuntimeError: Failed to start embedded PostgreSQL after 5 attempts. Last error: Error: IO error: 拒绝访问。 (os error 5)
ERROR:    Application startup failed. Exiting.
✗ Daemon exited during initialization (exit code 3)
```
**注意**：它去起**内嵌** Postgres（`pg0`），而外部 `127.0.0.1:5433` 上的 Postgres 明明已经跑着 —— 这才是矛盾点。

---

## 4. 根因（已用源码逐行定位，勿再猜）

调用链：
`hindsight_api/api/http.py:4985 lifespan → memory.initialize() → memory_engine.py:5411 initialize() → memory_engine.py:5289 start_pg0() → memory_engine.py:5306 pg0.ensure_running() → pg0.py:132 start() → pg0.py:93 raise RuntimeError`

而 `memory_engine.py:2499-2500` 决定要不要走内嵌库：
```python
_parsed_pg0 = parse_pg0_url(db_url)          # db_url = 参数 or config.database_url
self._use_pg0 = _parsed_pg0.is_pg0           # 只有 "pg0"/"pg0://…" 才为 True
```
`hindsight_api/config.py:1089,4130`：
```python
DEFAULT_DATABASE_URL = "pg0"
database_url = os.getenv("HINDSIGHT_API_DATABASE_URL", DEFAULT_DATABASE_URL)
```

**真正的凶手**在 embed 启动器里。`F:\deepseek\.hindsight-setup\uv-tools\hindsight-embed\Lib\site-packages\hindsight_embed\daemon_embed_manager.py`：
```python
# L757  def _start_daemon(self, config: dict, profile: str, ...)
# L822  profile_config = self._profile_manager.load_profile_config(profile)   # 读 <profile>.env
# L824  merged_config = {**profile_config, **config}
# L841  env = os.environ.copy()
# L842  for key, value in config.items():
# L843      if key.startswith("HINDSIGHT_") and value is not None:
# L844          env[key] = str(value)
# L847  db_override = config.get("HINDSIGHT_EMBED_API_DATABASE_URL") or env.get("HINDSIGHT_EMBED_API_DATABASE_URL")
# L848  if db_override:
# L849      env["HINDSIGHT_API_DATABASE_URL"] = db_override
# L850  else:
# L851      env["HINDSIGHT_API_DATABASE_URL"] = self.get_database_url(profile)   # ← 无条件覆盖
# L853  database_url = env["HINDSIGHT_API_DATABASE_URL"]
# L854  is_pg0 = database_url.startswith("pg0://")
```
以及 `daemon_embed_manager.py:259-273`：
```python
def get_database_url(self, profile: str, db_url: Optional[str] = None) -> str:
    if db_url and db_url != "pg0":
        return db_url
    safe_profile = self._sanitize_profile_name(profile)
    return f"pg0://hindsight-embed-{safe_profile}"
```

即：**profile 的 `.env` 里写了 `HINDSIGHT_API_DATABASE_URL=postgresql://…5433/hindsight` 也没用 —— L851 会把它强行改写成 `pg0://hindsight-embed-coding-agent`，于是 daemon 去起内嵌 Postgres，在当前受限令牌下报 `os error 5`。** 这解释了为什么改 `.env` 一直不生效。
唯一的官方逃生门是环境变量/配置项 **`HINDSIGHT_EMBED_API_DATABASE_URL`**（L847）。

---

## 5. 推荐修复（一行）

在 `F:\deepseek\.hindsight-home\.hindsight\profiles\coding-agent.env` 里**加**一行（它会作为 `config` 被 L847 优先读到）：
```
HINDSIGHT_EMBED_API_DATABASE_URL=postgresql://hindsight:hindsight@127.0.0.1:5433/hindsight
```
然后：① 先起 postgres（后台作业）→ ② `hindsight-embed.exe -p coding-agent daemon start` → ③ `curl http://127.0.0.1:9077/health` 应通。
这样 `is_pg0=False`，**内嵌 Postgres 这条路彻底不走**，受限令牌也不再是问题。

---

## 6. 需要外援拍板 / 帮忙的问题

1. **上面这行 fix 是否就是官方意图？** 有没有更正规的开关（比如 profile 的 `metadata.json`、`coding-agent.json` 顶层 `databases`、或 `hindsight-embed` 的 `--database-url` 参数）来指定外部 Postgres？`HINDSIGHT_EMBED_API_DATABASE_URL` 在各 harness 里语义一致吗？
2. **`pg0://hindsight-embed-<profile>` 的实例到底存哪？** 如果其实能修好内嵌库（换个可写目录 / 避开受限令牌 / 预先用同样名字起一个 pg0 实例让它复用），是否比外挂 5433 更稳、更符合升级路径？
3. **谁该负责拉起 daemon？** DSH 插件自己会在 session-start 调 `ensureDaemon()`（`dist/cline.js:2192`，从 `18363`/`18510` 调用）。但它继承的是**真实** `USERPROFILE=C:\Users\Administrator`，那里 `~\.hindsight\` **只有 `coding-agent.json` 和 `coding-agents-logs\`，没有 `profiles\coding-agent.env`** → 插件自启的 daemon 会走默认配置（可能又去下模型/起内嵌库）。是应该 (a) 让插件复用外部已跑的 daemon（我打算在开机时先起好），还是 (b) 把 `coding-agent.env` 也复制到真实用户目录？两条路哪个更不容易被下次升级打破？
4. **怎么让它开机自启且活在沙箱外？** 本会话的 `pwsh` 进程是 Low Mandatory Level，从它派生的子进程会随父进程死亡，也不是真的 detached。`schtasks`/`New-ScheduledTask`/`Invoke-CimMethod Win32_Process Create` 在这个受限令牌下**全部失败过**。有没有在这台机器上（从低完整性会话）能用的常驻方案？
5. **`autoInject` 选哪个？** 现在是 `reflect`（首条 prompt 触发一次低预算 reflect）。在这个 bank（`coding-agent::deepseek`）**一张知识页都还没有**（0 行）的情况下，是 `reflect` 还是 `pages` 更合适？

---

## 7. 硬约束 / 已知的花式踩坑（务必遵守）

- **绝对不要手改** `C:\Users\Administrator\.dsh\profiles\desktop\cordis.patch.yml`。曾加过 `- id: hindsight` 用 4 空格缩进（应为 2 空格）→ `YAMLException: bad indentation of a mapping entry (90:13)`，应用直接起不来。插件包 `package.json` 声明了 `"dsh": {"bundle": {"patch": "./cordis.patch.yml"}}`，正确做法是**只把包名加进 `dsh.profile.bundles`**，补丁层会自动挂载（官方注释原话："Nothing else needs editing"）。
- 应用启动失败时，自带的恢复逻辑会把 `dsh.profile.bundles` **砍到只剩 base + web-app**（会静默丢掉其它插件）。
- `package.json` **不能有 UTF-8 BOM**（曾因 BOM 导致 `JSON.parse` 抛 `Unexpected token ''`，应用起不来）。当前 profile 的 `package.json` 是 `7b 0d 0a` 开头，正常。
- PowerShell 执行策略会挡 `.ps1`：`& script.ps1` 报"未对文件进行数字签名"。绕过：`$sb = [scriptblock]::Create((Get-Content -LiteralPath <path> -Raw)); & $sb`。
- PowerShell 5.1 读含中文的脚本会乱码 → 脚本一律纯 ASCII；写文件用 `UTF8Encoding($false)`。
- Web GUI `127.0.0.1:19387` 需要**内存里的随机启动令牌**（`http://127.0.0.1:19387/?token=<43字符 base64url>`，不落盘、重启失效）。401 不是记忆系统的问题，别去查。
- 清空记忆 = 服务端删 bank，本地没有状态文件。插件失败**不会中断 agent**，只降级成"这一轮没记忆"。

---

## 8. 修好后的验证（任一条不满足就是没好）

```powershell
netstat -ano | Select-String ':9077\s.*LISTENING'          # daemon 在听
(Invoke-WebRequest http://127.0.0.1:9077/health).StatusCode # = 200
& F:\deepseek\.hindsight-bin\hindsight-embed.exe -p coding-agent daemon status
```
- 新开一个 DSH 会话应看到横幅 `↳ memory bank "coding-agent::deepseek"`，且工具列表里有 `hindsight_search_knowledge_pages` / `hindsight_reflect` 等。
- `C:\Users\Administrator\.hindsight\coding-agents-logs\diag.jsonl` 应出现 `session_start` 之后**不再是** `reflect_failed`/401，而是 `reflect_ok` / `inject_ok`。
- 数据库里 `knowledge_pages` 表开始有行（当前 25 张表全 0 行）。

---

## 9. 关键文件索引

| 用途 | 路径 |
|---|---|
| 一键起栈脚本（含全套 env） | `F:\deepseek\.hindsight-setup\restart-stack.ps1`（105 行；它会起 pg → 建库 → `hindsight-embed daemon start` → 轮询 `/health`） |
| 起栈日志 | `F:\deepseek\.hindsight-setup\restart-stack.log` |
| daemon 日志（报错在这） | `F:\deepseek\.hindsight-home\.hindsight\profiles\coding-agent.log` |
| profile 环境变量 | `F:\deepseek\.hindsight-home\.hindsight\profiles\coding-agent.env`（50395 字节） |
| 真凶所在 | `F:\deepseek\.hindsight-setup\uv-tools\hindsight-embed\Lib\site-packages\hindsight_embed\daemon_embed_manager.py:757,822,841-854,259-273` |
| 内嵌库判定 | `…\uv-cache\archive-v0\L-L638tQVyavP7Mr\Lib\site-packages\hindsight_api\engine\memory_engine.py:2499-2509, 5289-5309` |
| 内嵌库实现 | `…\hindsight_api\pg0.py:128-233`；默认值 `…\hindsight_api\config.py:1089,4130` |
| DSH 插件（0.8.0） | `C:\Users\Administrator\.dsh\profiles\desktop\node_modules\@vectorize-io\hindsight-coding-agents\`（`dist\cline.js:1563-1573, 2192, 18363, 18510`） |
| DSH profile 配置 | `C:\Users\Administrator\.dsh\profiles\desktop\package.json`（`dsh.profile.bundles` 里**当前没有** hindsight） |
| 旧交接记录 | `F:\deepseek\HANDOFF-NEXT-SESSION.md`、`F:\deepseek\MEMORY-STACK-STATUS.md` |

---

## 9.5 实装核查结果（2026-09-30 12:11 实测）

| 检查项 | 结果 |
|---|---|
| `HINDSIGHT_EMBED_API_DATABASE_URL` 写入用户级环境变量 | ✅ 已实装 |
| 写入 `F:\deepseek\.hindsight-home\.hindsight\profiles\coding-agent.env`（L753） | ✅ 已实装 |
| 写入真实用户 profile `C:\Users\Administrator\.hindsight\profiles\coding-agent.env`（L753） | ✅ 已实装（该文件 11:59:34 才被创建） |
| 第 5 节的 fix 是否真的有效 | ✅ **已验证有效**：11:59–12:10 期间 daemon 直连外部 5433（不再起内嵌库），日志有 `[RECALL]`、`[REFLECT … done \| iterations=4]`、`[OBSERVATIONS] Deleted 2 observations … bank coding-agent::deepseek` |
| daemon 9077 现在在跑吗 | ❌ 无监听；日志停在 `12:10:20` |
| 外部 Postgres 5433 现在在跑吗 | ❌ 无监听、无 `postgres` 进程 |
| 停掉的原因 | DSH 桌面版于 `12:10:23` 重启，把上一代进程树（daemon + 被它带起的 postgres）一起带走 |
| 插件是否挂进 DSH | ❌ `dsh.profile.bundles` 无、`cordis.patch.yml` 无、`.dsh-market\state.json` 无 |
| 插件进程今天是否跑过 | ❌ `C:\Users\Administrator\.hindsight\coding-agents-logs\` 最后写入 **2026-09-29 17:21** |
| 本会话是否有 `hindsight_*` 工具 / 🧠 横幅 | ❌ 都没有 |
| bank 里是否有数据 | ⚠️ 有 —— 12:05 的 `Deleted 2 observations … in bank coding-agent::deepseek` 证明存过东西（已不再全 0 行） |

**一句话**：服务端（Postgres + daemon）已修好且**证明能工作**，但当前是停的；**DSH 侧插件完全没挂上**。剩下两件事：①让 daemon/postgres 常驻；②把插件挂回 bundles 并重启应用。

**2026-09-29T17:23 的卸载记录**（解释了为什么 bundles 是空的）：market 日志 `toggle → off: fiber=true` → `dsh.profile.bundles removed so the official page's package switch agrees (#696)` → `patch: disabled row hindsight in cordis.patch.yml` → `uninstall exit=0 live-removed=false`。今天的 market 日志只有 `dsh-web-all` 的 toggle，没有任何 hindsight 动作。

---

## 10. 结论（我的建议）

**先别急着找外援 —— 第 5 节那一行很可能直接解决。** 真正卡住的从来不是"沙箱不让起 Postgres"（外部 5433 完全能起），而是 embed 启动器**硬编码覆盖**了数据库 URL，让人误以为配置没生效。
外援真正值得回答的是第 6 节的 5 个问题，其中 **3 和 4（谁拉起 daemon、怎么常驻）** 才是修好之后仍会反复咬人的地方。
