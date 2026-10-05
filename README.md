# Watchlamp

*A status light for Claude Code on macOS: one lamp per session, readable from across the room.*

适用于 Claude Code 的醒目提醒灯：在 Mac 屏幕上放一块悬浮灯板，每个 Claude Code 会话一盏灯，
哪个项目在跑、哪个在等你，隔着半个房间也看得清。桌面版（Code 标签页）和终端里的 `claude` 都支持。

![灯板截图：运行中、等你操作、已完成三种状态](screenshot.png)

| 灯（默认"经典"配色） | 含义 | 下面的文字 |
|---|---|---|
| 🟢 绿色，光晕呼吸，灯圈上有一道光在转 | 运行中 | 本轮已运行多久、正在做什么（如"命令 · 运行测试"） |
| 🔴 红色 + ✋，快速闪烁 | 等你操作：授权确认、回答问题、确认计划；出错停下时显示 ❗ | 等了多久、等的是什么 |
| ⚫ 熄灭 + ✓ | 空闲：这一轮做完了 | 多久前完成、用时多少 |

另外可以让**屏幕边框发光**（所有屏幕一起亮，鼠标可以直接穿过去点）。默认只在"等你操作"时闪框，也可以改成运行中也亮。

界面支持 12 种语言：English、Español、Português (Brasil)、Français、Deutsch、Italiano、Русский、العربية、日本語、한국어、简体中文、繁體中文。默认跟随系统语言，也可以在菜单"语言"里单独切换；阿拉伯语下灯板会左右镜像。

## 使用

- **移动**：直接拖灯板，放在主屏或扩展屏都行，位置会记住。也可以用菜单"把灯板移到"一键放到某块屏幕。
- **点一下灯**：切换到这个会话所在的 app（Claude 桌面版、终端、VS Code……）。
- **右键灯板**或点**菜单栏的小圆点**打开设置：
  - 灯的大小：小 / 中 / 大 / 特大 / 巨大（离得远就选大一点）
  - 文字大小：小 / 中 / 大 / 特大（和灯的大小分开调）
  - 横排 / 竖排（横排一行最多 4 盏，多了自动换行）
  - 配色：经典（运行绿、等你红）、轮到你（干活红、点一下黄、轮到你绿，站在你的角度看）、色弱友好（运行蓝、等你橙）
  - 显示正在做什么、屏幕边框发光、没有会话时隐藏、登录时自动启动
  - 演示三种状态（12 秒，在灯板上放三盏示例灯）、语言
- 同一个项目开了多个会话时，会显示成"项目名 #1""项目名 #2"。鼠标停在灯上能看到完整路径。

> 小提示：MacBook 菜单栏图标太多时，macOS 会把放不下的图标藏到刘海后面。菜单栏里看不到小圆点时，右键灯板打开的是同一个菜单。

## 安装 / 更新 / 卸载

```bash
git clone https://github.com/xiongqiutang/watchlamp.git
cd watchlamp
./install.sh     # 编译 → 装到 ~/Applications/Watchlamp.app → 写入钩子 → 启动
./uninstall.sh   # 移除钩子、登录项、App 和状态文件
```

需要 macOS 13 或更新版本、Xcode 或 Command Line Tools（`swiftc`）和 python3。安装时会先把
`~/.claude/settings.json` 备份到 `~/.claude/watchlamp/backups/`，只增删命令里带 `Watchlamp` 的钩子，其他设置原样保留。

## 工作原理

```
Claude Code ──hook 事件(JSON)──▶ Watchlamp hook ──▶ ~/.claude/watchlamp/sessions/<会话id>.json
                                                                │ 每 0.5 秒读取
                                 悬浮灯板 + 屏幕边框 + 菜单栏图标 ◀─┘
```

- 钩子注册在 `~/.claude/settings.json`：SessionStart / UserPromptSubmit / PreToolUse / PostToolUse /
  PermissionRequest / Notification / Stop / StopFailure / SubagentStart/Stop 等 16 个事件。
- `Watchlamp hook` 每次约 15 ms，不输出任何内容、永远返回 0，不会拦截或改变 Claude 的行为。
- 整个 App 约 420 KB；CPU 约 0.8%，内存约 15 MB（macOS 上一个只有菜单栏图标和一个窗口的空白 App 就要约 12 MB）。
- 会话的 Claude Code 进程退出后，灯会在 2 秒内自动消失；12 小时没有动静的会话也会被清理。
- 后台子代理 / 工作流还在跑时灯保持亮着；后台 shell（比如 dev server）不算"运行中"。

## 已知限制

- 批准授权后，要等这个工具执行完灯才从"等你"变成"运行中"（Claude Code 没有"已批准"这个事件）。
- 按 Esc 或停止按钮中断时没有 Stop 事件，灯板通过读会话记录发现中断，最多晚 2 秒熄灯。

## 开发

```
Sources/                  Swift 源码：Hook（事件→状态）、Model、Store、Board（灯板）、EdgeGlow（屏幕边框）、App（菜单）、Lang（多语言）
Resources/*.lproj/        各语言的界面文字（键就是英文原文，缺的翻译会显示英文；selftest.sh 会检查每种语言是否齐全）
scripts/hooks.py          安装 / 移除钩子
scripts/selftest.sh       用模拟事件跑一遍状态机
scripts/devtools.sh       开发版命令（不打包进 App）：snapshot 离屏渲染灯板截图（可指定语言）、status 列出会话
scripts/RenderIcon.swift  编译时画 App 图标
```

---

Watchlamp 是个人开源项目，与 Anthropic 没有关联。Claude 和 Claude Code 是 Anthropic 的商标。
