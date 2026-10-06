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
| `--primary` | 开 | niri + 卫星 0.8.3 下 PRIMARY（中键）两个方向都不通，实测见 diagnosis。 |
| `--aggressive-claims` | **不开** | 开了就重新变成抢 owner，正是本方案要消除的问题。 |

其他可调项（`--sync-mode eager`、`--transfer-timeout`、`--skip-sensitive`）
写在 drop-in 的注释里。

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

- 服务启动瞬间 PRIMARY 的首次 `startup_fill` 可能产生 1–2 条
  `level=warn … reason=empty-source`。之后不再出现，属良性。
- clipferry 用 `ext-data-control-v1`（niri 支持）。若换到只支持
  `wlr-data-control-v1` 的合成器，`clipferry --oneshot-check` 会报出来。

## 上游引用

- xwayland-satellite `src/xstate/selection.rs`、`ARCHITECTURE.md`、issues [#485](https://github.com/Supreeeme/xwayland-satellite/issues/485) / [#433](https://github.com/Supreeeme/xwayland-satellite/issues/433) / [#91](https://github.com/Supreeeme/xwayland-satellite/issues/91)
- clipferry `DESIGN.md` §4.2 / §4.3 / §10.1
- astrand/xclip [#43](https://github.com/astrand/xclip/issues/43)（大 buffer / INCR）
- Mozilla bug [1942284](https://bugzilla.mozilla.org/show_bug.cgi?id=1942284)（Niri 复制图片 hang）
