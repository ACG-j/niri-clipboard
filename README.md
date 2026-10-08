# niri-clipboard

niri + [xwayland-satellite](https://github.com/Supreeeme/xwayland-satellite) 下
X11 ⇄ Wayland 剪切板的**配置与验证**项目。

**这不是一个剪切板桥的实现**——桥用上游现成的
[clipferry](https://github.com/jmylchreest/clipferry)。本仓库只固化：

- 该怎么配（systemd drop-in）
- niri 侧该注意什么
- 怎么一键装 / 一键撤
- 怎么验证它真的没坏（含一个能测"多 target 是否透传"的 X11 owner 工具）
- 为什么是这么配的（[docs/diagnosis.md](docs/diagnosis.md)）

## 30 秒版本

```bash
paru -S clipferry          # 桥本体（上游）
./install.sh --verify      # 装 drop-in + 处理 niri 配置 + 起服务 + 回归
```

撤销：

```bash
./uninstall.sh
sudo pacman -Rns clipferry
```

## 为什么要这么做

在这个组合下，**不要再自己写 xclip 版的桥**。用 xclip + wl-clipboard + clipnotify
做双向同步会在同一块 X11 `CLIPBOARD` 上造出**第二个 owner**，与卫星内置的
selection 桥互抢，典型后果三连：

| 症状 | 根因 |
| --- | --- |
| Wayland / X11 双向都不通 | 两桥互相覆盖，最后双方一起卡死（X11 owner 变 `0x0`） |
| 图片传到 X11 **卡死** | xclip 对大 buffer 走 INCR 且并发请求处理有缺陷，与卫星互锁 |
| 带格式文本粘出来只剩纯文本 | 单 target + MIME 优先级把 `text/plain*` 排在 `text/html` 前 |

完整证据链：**[docs/diagnosis.md](docs/diagnosis.md)**。

clipferry 的解法是 **backstop 模式**：被动监听两侧，复制后等 200 ms，
别人（比如卫星）补位了就**什么都不做**，只有没人补位才接管。
于是"桥 vs 桥"结构性地不可能发生。

## 配置内容

`config/systemd/clipferry.service.d/eager-size.conf`：

| 参数 | 值 | 为什么 |
| --- | --- | --- |
| `--eager-max-size` | `256M` | clipferry 在 W→X 方向必须先抓载荷再声明所有权（上游 `DESIGN.md` §4.2）。**超过上限的类型会被丢弃**。默认 10M 会让大截图在 Wayland→X11 时凭空消失。 |
| `--aggressive-claims` | **不开** | 开了就重新变成抢 owner，正是本方案要消除的问题。 |
| `--primary` | **不开（已踩坑移除）** | 开了会与 xwayland-satellite 形成 PRIMARY 自维持循环，详见下方“已知坑”。 |

其他可调项（`--sync-mode eager`、`--transfer-timeout`、`--skip-sensitive`）
写在 drop-in 的注释里。

### 已知坑：`--primary` 会形成循环（2026-10-08）

开了 `--primary` 后，clipferry 与 xwayland-satellite 会在 PRIMARY 上互相触发：

```text
clipferry 抢 X11 PRIMARY → 卫星把该 claim 镜像回 Wayland
  → clipferry 又看到 Wayland PRIMARY 变化 → 再抢 X11 → …
```

实测一个 boot 内 475 次 claim，其中 `sel=primary` 占 **469** 次
（447 次是 `side=x11 sel=primary reason=proxy-wayland`），而真正有用的
CLIPBOARD claim 只有 6 次。X11 应用每次选中文字都会设置 PRIMARY，
聊天时极其频繁，等于给 X11 客户端叠加持续的 `SelectionClear` 冲击。

对照实验（外部只做 5 次 PRIMARY 更新）：

| clipferry 配置 | claim | 卫星 selection 错误 |
| --- | --- | --- |
| 关闭 | 0 | 0 |
| **无 `--primary`** | **0** | **0** |
| 有 `--primary` | 5 | 2 |

所以默认关闭。代价是中键（PRIMARY）不桥接——反正原本两个方向也不通。

## 目录结构

```text
niri-clipboard/
├── README.md
├── install.sh                      幂等安装/更新
├── uninstall.sh                    回滚
├── config/systemd/
│   └── clipferry.service.d/
│       └── eager-size.conf         ← 参数唯一真源
├── niri/
│   └── clipboard.kdl               niri 侧注意事项 + 手工启动写法
├── tools/
│   ├── clip-verify.sh              双向往回归矩阵（10 项）
│   ├── clip-multi.c                多 target 的 X11 CLIPBOARD owner（测富文本用）
│   ├── freeze-witness.sh           机器“假死”现场取证器（非剪切板专用，见下）
│   └── Makefile
└── docs/
    └── diagnosis.md                现场证据与根因分析
```

## install.sh 做了什么

1. 检查 `clipferry` / `wl-clipboard` 是否就绪，有 `clipsync` 残留会警告
2. 装 drop-in 到 `~/.config/systemd/user/clipferry.service.d/`
3. 备份 niri 配置到 `config.kdl.before-niri-clipboard-<ts>`，然后：
   - 注释掉所有未注释的 `spawn-at-startup "clipsync"`
   - 插入一个可识别的托管块（`// >>> niri-clipboard (managed by …) >>>`）
   - `niri validate` 校验，失败就报错让你还原
4. `systemctl --user enable --now clipferry.service`

**幂等**：托管块已存在就跳过插入；重复跑不会重复改配置。
`--no-niri` 可跳过第 3 步。

## 验证

```bash
tools/clip-verify.sh              # CLIPBOARD 双向 8 项
tools/clip-verify.sh --primary    # 再加 PRIMARY 2 项
tools/clip-verify.sh --png big.png   # 指定测试图（默认挑最大的 niri 截图）
```

要过 10/10 才算好。测试项：

```text
 1 W->X 文本              2 X->W 文本
 3 W->X 图片（强制 INCR）  4 X->W 图片
 5 X->W 富文本多 target    6 W->X 富文本
 7 text/uri-list          8 死锁自检（大图流量后 TARGETS 是否仍秒回）
 9 W->X PRIMARY          10 X->W PRIMARY
```

### 为什么需要 `clip-multi`

`xclip` 一次只能提供**一个** target，所以根本测不出
"复制一段带格式的文本，粘出来格式还在不在"。
`tools/clip-multi.c` 是一个最小的 Xlib 程序，自己当 X11 `CLIPBOARD` owner，
同时广告 `TARGETS` / `TIMESTAMP` / `UTF8_STRING` / `STRING` /
`text/plain` / `text/plain;charset=utf-8` / `text/html`，
然后检查 Wayland 侧是否**全部**收到。

```bash
cd tools && make          # 编译
DISPLAY=:0 ./clip-multi   # READY 后到别处 wl-paste --list-types 看看
```

## 排查

```bash
# 桥的每一个决策（coexist / claim / paste）
journalctl --user -u clipferry.service -f

# 交叉验证：卫星自己的 selection 日志
journalctl --user -b | grep -iE 'satellite.*(selection|clipboard|incr)'

# X11 CLIPBOARD 是否还有人持有、是否应答（卡死时 owner 常是 0x0 或超时）
DISPLAY=:0 timeout 5 xclip -selection clipboard -t TARGETS -o

# 当前到底有几个东西在抢
ps -eo pid,ppid,args | grep -E 'clipsync|xclip|clipnotify|wl-paste|clipferry'
```

`clipferry` 日志里这两个事件是健康的信号：

```text
event=coexist  side=x11 action=observe-wm-claim    ← 卫星的 claim 被识别为“桥”，不回环
reason=other-bridge-acted                          ← 卫星出手了，clipferry 主动让位
```

## 已知小瑕疵

- ~~服务启动瞬间 PRIMARY 的首次 `startup_fill` 可能产生 1–2 条
  `level=warn … reason=empty-source`。~~ 已随 `--primary` 移除而消失。
- clipferry 用 `ext-data-control-v1`（niri 支持）。若换到只支持
  `wlr-data-control-v1` 的合成器，`clipferry --oneshot-check` 会报出来。

## 附：WeChat / QQ「窗口假死」排查（结论：与剪切板无关）

这套剪切板配置曾被怀疑导致微信/QQ 假死。排查结论见
[docs/diagnosis.md](docs/diagnosis.md) 的 2026-10-08 章节，要点：

- **不是剪切板**：自述触发时机是「滚动/加载消息」与「挂着就卡」，不含复制粘贴。
- **不是系统资源饿死**：CPU 全停等 `avg300=0.00%`、内存 `0.05%`、
  磁盘空闲、50MB+fsync 仅 0.027s、无 OOM / 无段错误 / 无文件系统错误。
- 「I/O 风暴」那组读数（PSI io ≈56%）**是排查命令自己造成的**：
  `sudo du -xhd1 /` 扫 476GB 元数据、`grep -r` 读大日志，而 Pi 本身跑在
  `app-niri-ghostty-*.scope` 里。静默重测后无法复现。
- 唯一真实的 D（不可中断等待）线程是 `kworker+…i915_flip`，且只间歇出现
  （vblank 等待），不是持续挂死。
- 尚未排除的嫌疑：WeChat 以 `FCITX_QT_USE_SYNC=1` 启动（同步输入法调用）；
  niri 偶发 `GL_INVALID_VALUE in glTexSubImage2D`（仅 4 次／boot）。

### freeze-witness：把「卡死那一刻」抓下来

卡死往往几秒就过去，事后从日志里什么都看不到。`tools/freeze-witness.sh`
常驻采样，把现场落盘：

```bash
install -Dm755 tools/freeze-witness.sh ~/.local/bin/freeze-witness
freeze-witness start 3        # 每 3s 一次轻量采样，命中异常自动落深度快照
freeze-witness tail 20        # 看最近采样
freeze-witness dump frozen    # 卡住的那一刻立刻手动抓一份
dumps 目录: ~/.local/state/freeze-witness/dumps/
```

快照包含：PSI 三件套、内存/swap、磁盘与设备统计、**全线程** D 状态及其内核栈、
关注进程的线程 wchan 分布、CPU Top、GPU 状态、内核告警、合成器/应用近期告警。

> 注意：判断 D 状态要扫 **`/proc/*/task/*`（线程级）**，`ps` 默认看不到子线程；
> 且线程名可能含空格（如 `Msg Db Writer`），解析 `/proc/PID/stat` 必须从**最后一个
> `)`** 之后取状态字符，否则会得到假阳性。

## 上游引用

- xwayland-satellite `src/xstate/selection.rs`、`ARCHITECTURE.md`、issues [#485](https://github.com/Supreeeme/xwayland-satellite/issues/485) / [#433](https://github.com/Supreeeme/xwayland-satellite/issues/433) / [#91](https://github.com/Supreeeme/xwayland-satellite/issues/91)
- clipferry `DESIGN.md` §4.2 / §4.3 / §10.1
- astrand/xclip [#43](https://github.com/astrand/xclip/issues/43)（大 buffer / INCR）
- Mozilla bug [1942284](https://bugzilla.mozilla.org/show_bug.cgi?id=1942284)（Niri 复制图片 hang）
