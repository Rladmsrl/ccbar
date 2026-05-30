# 悬浮标签 · Agents 控制台 — 实现规划

> 目标:把悬浮标签的 AGENTS 区从「只读列表」升级成「mini agent view」——
> 用户在悬浮标签里就能停止 / 重启 / 删除 / 查看输出 / 收到「需输入」提醒,
> 不必再每次 `claude agents` 全屏接管终端。

本文档是和下一个大功能一起打磨的设计草稿,先把可行性、接口和实现拆解记下来。

---

## 一、现状

- `ClaudeAgentsService` 每 10 秒跑 `claude agents --json`,把结果解析成 `[ClaudeAgent]`
- 字段:`pid` / `sessionId` / `cwd` / `kind` (interactive | background) / `status` (idle | busy) / `name` / `startedAt`
- 悬浮标签 `FloatingAgentsList` 渲染前 5 条:status 圆点 + name + 项目目录·已跑时长 + INT/BG 胶囊
- 超出 5 条显示 "+ N more"
- 没有任何交互按钮

## 二、能拿到的所有 Claude Code 接口

### 2.1 CLI 子命令(走 `Process`,无 TTY 也能调)

| 命令 | 用途 | 是否需要 TTY |
|---|---|---|
| `claude agents --json [--cwd <path>]` | 已用 · 列出后台 session | 否 |
| `claude stop <id>` (= `claude kill <id>`) | 停止 session | 否 |
| `claude respawn <id>` / `--all` | 重启 session(保留对话)| 否 |
| `claude rm <id>` | 删除 session + worktree(无未提交改动时)| 否 |
| `claude logs <id>` | 拿最近输出 | 否 |
| `claude --bg "<prompt>" [--name X] [--agent Y] [--model Z]` | 从壳里 dispatch 新后台 session | 否 |
| `claude daemon status` | supervisor 健康检查 | 否 |
| `claude attach <id>` | 接管 session 对话 | **是** —— 需 `open -a Terminal …` 这种走法 |

### 2.2 直接读的状态文件(无 IPC,纯 JSON)

| 路径 | 用途 |
|---|---|
| `~/.claude/daemon/roster.json` | 当前所有 session 列表(`--json` 的真实数据源)|
| `~/.claude/jobs/<id>/state.json` | 单个 session 的实时状态 —— **比 `--json` 多了 `Completed/Failed/Stopped` 等细分状态** |
| `~/.claude/daemon.log` | supervisor 日志 |

> `--json` 的 `status` 只有 idle / busy 两值。要在 UI 上区分 Working / Needs input / Idle / Completed / Failed / Stopped 这 6 档,就得读 `state.json`,或者走 Hook(见下)。

### 2.3 Hooks 系统(28 个事件)

把 hook 配置注入 `~/.claude/settings.json` 的 `hooks` 字段。每个事件触发时,CC 把 JSON payload
通过 stdin 喂给我们指定的命令(或 HTTP endpoint)。

对悬浮标签最有用的事件:

| 事件 | 用途 |
|---|---|
| `SessionStart` / `SessionEnd` | session 起停的精确时刻 |
| `Stop` / `StopFailure` | 一轮对话结束 / 失败,可分 Completed/Failed |
| `Notification`(matcher = `permission_prompt`)| **关键** —— 捕获「agent 卡在等用户授权」的瞬间 |
| `TaskCreated` / `TaskCompleted` | 任务状态 |
| `UserPromptSubmit` | 哪个 session 在被人主动用 |

Hook 类型可选:
- `command` —— 跑 shell 脚本,JSON 进 stdin
- `http` —— POST 到 URL
- `agent` —— 派一个子 agent 做判断(实验性)

---

## 三、实现拆解(按价值/成本排序)

### 阶段 A — 行内控制按钮 ⭐⭐⭐

> 30 行 Swift,纯 CLI 子进程。最低成本最高价值。

`FloatingAgentRow` 加上三个按钮(右侧 trailing):

- ⏹ **Stop** → `claude stop <id>`
- 🔄 **Respawn** → `claude respawn <id>`
- 🗑 **Remove** → `claude rm <id>`(操作前弹个 confirm)

**实现**:`ClaudeAgentsService` 加方法 `stop(id:) async`, `respawn(id:) async`, `remove(id:) async`,
都走 `Process` 跑对应 CLI,完成后立即 `refresh()` 更新列表。

**风险**:
- `rm` 会删 worktree。如果该 worktree 里有未提交改动,CLI 会拒绝并打印路径 —— 把
  错误打回 UI 即可(actionMessage 弹一行)
- Stop 是软停。要硬终止得用 `kill`(同义),目前 `stop` 足够

### 阶段 B — Peek 弹窗 ⭐⭐⭐

> 中等成本,体验提升大。

鼠标悬停一行 → 显示一个小浮层,内容是 `claude logs <id> --tail 20`(或类似)
截取的最近输出。

**实现**:
- 用 `.popover(isPresented:)` 或简单的 hover overlay
- 进入悬停时 spawn `claude logs <id>`,把 stdout 流式塞进 popover 里
- 离开悬停时把命令 kill 掉(免得后台一直挂)

**优化**:Peek 弹出时也并发拉一次 `state.json`,把更细的状态显示出来。

### 阶段 C — "Needs Input" 红点徽标 ⭐⭐⭐

> 是 agent view 那个 "Needs input" 分组的能力 —— 哪个 session 在等你授权,小红点提示。

**实现链路**:

1. 装一个 Notification hook 到 `~/.claude/settings.json`:

   ```json
   {
     "hooks": {
       "Notification": [
         {
           "matcher": "permission_prompt",
           "hooks": [
             {
               "type": "command",
               "command": "/path/to/notification-bridge.sh"
             }
           ]
         }
       ]
     }
   }
   ```

2. `notification-bridge.sh` 把 stdin JSON 写到
   `~/Library/Application Support/CCBar/AgentNotifications/<session_id>.json`,
   并 touch 时间戳

3. Swift 端 `ClaudeAgentNotificationWatcher`:
   - `DispatchSourceFileSystemObject` 监听这个目录的 `.write` / `.attrib`
   - 一有变化就重读目录里所有 .json,把 sessionId 集合塞给 `ClaudeAgentsService`
   - 同时设一个超时(比如 5 分钟没刷新就视为已解决,删文件)

4. UI:
   - `FloatingAgentRow` 看到自己的 sessionId 在「needs input」集合里 → 显示红点
   - 顶部 AGENTS header 显示 `2 NEEDS INPUT` 之类的小标
   - 列表排序:needs-input 优先,然后 busy,然后 idle

**安装策略**:跟 statusLine bridge 同款 —— 设置里加个开关「让悬浮标签捕获 CC 通知」,
开启时往 `~/.claude/settings.json` 的 `hooks.Notification` 写入我们的配置,关闭时移除。
存原始配置到 state 文件,可一键还原(参考 `ClaudeUsageLimitBridgeInstaller` 的设计)。

### 阶段 D — Dispatch 输入框 ⭐⭐

> 悬浮标签底部加个输入框,Enter 起新 bg session。空间小,不一定值得做。

```swift
TextField("Dispatch task…", text: $prompt)
    .onSubmit {
        Task {
            await env.claudeAgents.dispatch(
                prompt: prompt,
                cwd: env.preferences.lastSelectedCWD
            )
            prompt = ""
        }
    }
```

`dispatch` 走 `claude --bg "<prompt>" --name auto`,完成后 refresh。

**问题**:
- 输入太短(< 4 chars)会被 CC 拒,UI 要先校验
- 默认 cwd 怎么选?— 可以记上次 attach 过的目录,或让用户从列表里点行选 cwd

### 阶段 E — Attach 按钮 ⭐

> 点开后开新的 Terminal 窗口跑 `claude attach <id>`。低优。

```swift
let script = """
tell application "Terminal"
    activate
    do script "claude attach \(sessionId)"
end tell
"""
NSAppleScript(source: script)?.executeAndReturnError(nil)
```

不是所有人都用 Terminal.app(iTerm / Ghostty 等),可能要按用户偏好分支。

### 阶段 F — 6 档状态显示 ⭐⭐

> Working / Needs input / Idle / Completed / Failed / Stopped

`--json` 不给这些。两种拿法:

1. 读 `~/.claude/jobs/<id>/state.json` —— 直接,但格式没文档,得逆向
2. 用 Hook(SubagentStop / Stop / StopFailure)+ 文件监听 —— 干净,但要装钩子

推荐先走 1,实在不行再加 hook。

---

## 四、悬浮标签布局调整(配合上面)

当前(高度 ~140px):
```
AGENTS                              5
● agent 1     project · 5m    [INT]
● agent 2     project · 12m   [BG]
...
```

加完控制后(高度 ~170px,每行变高 6px 加按钮槽):
```
AGENTS · 1 NEEDS INPUT              5
🔴 ● agent 1   project · 5m  [INT] ⏹🔄🗑
● agent 2     project · 12m  [BG]  ⏹🔄🗑
+ 3 more
[ Dispatch task…             ⏎ ]   ← 阶段 D
```

按钮在 hover 时才显示,平时只有红点/状态圆点。

---

## 五、待定问题

- **悬浮标签宽度** 当前 320pt,加按钮后会拥挤。是否扩到 360pt?或只在 hover 时显示按钮?
- **多 agent 批量操作** 比如「停掉所有 idle 超过 1 小时的」—— 暂不做,留给 agent view 全屏
- **`claude` 二进制路径漂移** 我们目前在 `~/.local/bin/claude` / Homebrew / `/usr/local/bin` 几条候选里找。
  如果用户走 `~/.local/share/claude/versions/X.Y.Z/claude` 这种版本化路径,需要扩展候选(用 `which claude` 兜底?)
- **Notification hook 卸载策略** 卸载时如果用户自己后来又改了 `Notification` 配置,我们要不要恢复?
  参照 statusLine bridge 的 `state.json + 对比 currentCommand` 思路
- **节流** 现在 service 10 秒一拉 `claude agents --json`。加了 hook 通知后,事件驱动 + 兜底轮询?
- **CC 版本依赖** agent view 要求 v2.1.139+;`claude agents --cwd` 要 v2.1.141+;
  `--permission-mode` / `--model` 给 `claude agents` 要 v2.1.142+。需要检测版本并 graceful degrade

---

## 六、推荐落地顺序

1. **阶段 A**(停止/重启/删除)+ **阶段 B**(peek)—— 一起做,1-2 天
2. **阶段 C**(Needs input 红点)—— 单独一轮,需要 hook installer + watcher,1-2 天
3. 视用户反馈再决定 D/E/F

阶段 A+B+C 做完悬浮标签就是个独立可用的 mini agent view,
不依赖用户开终端窗口跑 `claude agents`。
