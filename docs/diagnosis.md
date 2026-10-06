# 诊断记录：niri + xwayland-satellite 下的剪切板三重故障

> 2026-10-07 在 `ation_ciger` 的 Arch + niri 26.04 + xwayland-satellite 0.8.3 机器上实测。
> 本文件是**证据留档**，不是教程。要装/改请看 `../README.md` 和 `../install.sh`。

## 现场环境

| 项 | 值 |
|---|---|
| 发行版 | Arch Linux (rolling) |
| 合成器 | niri 26.04 (`XDG_SESSION_TYPE=wayland`, `WAYLAND_DISPLAY=wayland-1`) |
| X11 | `xwayland-satellite 0.8.3`（niri 通过 `-listenfd` socket 激活启动） |
| X display | `:0`，socket `/tmp/.X11-unix/X0` |
| 当时的桥 | `clipsync-git r20.ecbf735`（自研，xclip + wl-clipboard + clipnotify） |
| 可用工具箱 | `wl-clipboard 2.3.0`、`xclip 0.13`、`clipse`、dms(quickshell) clipboard |

## 关键事实：卫星本来就带桥

`xwayland-satellite` 0.8.3 的 `src/xstate/selection.rs` 已经实现了完整的
X11 ↔ Wayland selection 同步：

- **保留全部 MIME target**：`handle_target_list()` 抓 X11 的 `TARGETS`，过滤掉
  `TARGETS`/`MULTIPLE`/`SAVE_TARGETS` 后，**逐个**建 `SelectionTargetId`
  （`text/html`、`image/png`、`text/uri-list`、以及应用私有 atom 全都保留）。
- **正确处理 INCR**，两个方向都有；X11→Wayland 方向还专门排队：
  > A lot of X applications do not anticipate the possibility of multiple requests
  > for its owned selection to need the INCR transfer mechanism and will stop
  > sending the necessary `PropertyNotify` events, hanging Wayland transfer
  > receivers. To remedy this, every target requested by Wayland is put into a
  > FIFO queue …

所以问题不是"缺一个桥"。

## 症状 1：X11/Wayland 双向都不通

清理前（clipsync 在跑）实测：

```text
X11 CLIPBOARD owner = 0x4c00001   (xclip -sel clip -i -t image/png)
xclip -selection clipboard -t TARGETS -o    →  超时，5s 无应答
wl-paste --list-types                       →  image/png
___
326819  xclip -sel clip -i -t image/png          ← 占着 CLIPBOARD
326857  xclip -selection clipboard -t TARGETS -o ← clipsync 的 X2W 死读，挂了 9 分钟
clipsync 线程 TID 2961: wchan = do_wait          ← 永不恢复
niri journal: WARN niri::handlers: error writing selection: BrokenPipe
```

清理后（只有卫星）实测，**两个方向仍然全不通**：

```text
[1] wl-copy "WAYLAND-TEXT-MARKER"  →  sleep 2  →  X11 CLIPBOARD owner = 0x0
                                                   xclip -o = Error: target STRING not available
[2] printf BBB-x11 | xclip -i -t UTF8_STRING  →  sleep 2  →  wl-paste -n = AAA-wayland（还是上一次的）
```

卫星日志显示它**看见**了变化却没能落地：

```text
satellite: new CLIPBOARD owner: Window { res_id: 4194305 }
satellite: CLIPBOARD set from X11
```

这与上游 [issue #485](https://github.com/Supreeeme/xwayland-satellite/issues/485)
描述的状态一致：Wayland 侧有 offer，X11 侧 `CLIPBOARD` 无 owner，聚焦切换也不恢复。

## 症状 2：图片传到 X11 卡死

两个叠加因素：

1. **clipsync 用 xclip 写大图**：`xclip -sel clip -i -t image/png`。
   xclip 对超过阈值（~几百 KB）的 buffer 走 INCR，而它的并发请求处理有缺陷——
   传输期间会 fork 子进程服务数据，其它请求被丢弃
  （[astrand/xclip#43](https://github.com/astrand/xclip/issues/43)）。
2. **两个 owner 互相触发**：clipsync 把 X11 抢走 → 卫星把 X11 镜像回 Wayland →
   clipsync 的 `wl-paste --watch` 又看到变化 → 回读 X11 `TARGETS` →
   正好撞上 xclip 的 INCR 传输窗口 → 双方都卡住。

实测症状即 `xclip -t TARGETS -o` 永久不应答（症状 1 里那条）。

## 症状 3：带格式文本粘不出来

`clipsync/src/main.rs` 的 MIME 选择是**优先级列表 + 单一 target**：

```rust
// X2W 方向（Wayland 侧的实际顺序）
} else if types_str.contains("text/plain;charset=utf-8") {
    ("text/plain;charset=utf-8", "text/plain", "text")
} else if types_str.contains("UTF8_STRING") { ... "text" }
} else if types_str.contains("text/plain")  { ... "text" }
} else if types_str.contains("text/html")   { ("text/html", "text/html", "raw") }
```

而写 X11 时只写一个 target：

```rust
let target_t = match sync_mime {
    "text/plain;charset=utf-8" | "text/plain" => "UTF8_STRING",
    other => other,
};
write_clipboard("xclip", &["-sel", "clip", "-i", "-t", target_t], &write_data);
```

浏览器/X11 应用**永远同时**提供 `text/plain;charset=utf-8` 和 `text/html`，
所以 `text/html` 分支永远走不到 → 富文本 100% 被降级成纯文本。
即使走到了，单 target 也意味着纯文本编辑器就粘不出来了。

## 额外发现：PRIMARY（中键）两边都不通

```text
wl-copy -p "P-WAYLAND-MARK"                     →  xclip -selection primary -o  =  （空）
printf P-X11-MARK | xclip -selection primary -i →  wl-paste -p                  =  P-WAYLAND-MARK（旧值）
```

## 修复

换成 [clipferry](https://github.com/jmylchreest/clipferry) 0.0.3，默认 **backstop 模式**。

它的 `DESIGN.md §10.1` 正是作者在 niri + xwayland-satellite 0.8.1 上实测后写的：

- 卫星的桥 "real but partial"，会漏 games/Wine、无焦点流程；
- **bridge-vs-bridge** 会让收敛论证失效，产生机械速度的 ownership 乒乓、
  取消真实 source，甚至让 Wine/Proton 游戏挂死；
- 所以 clipferry 只做 **"claims land only in voids"**：
  被动监听两侧（XFIXES + ext-data-control，零成本零声明），
  复制后等 200ms `GAP_WINDOW`，别人补位了就什么都不做。

实测共存证据（`journalctl --user -u clipferry.service`）：

```text
event=coexist wm_window=0x200005                        ← 认出卫星 WM 窗口
event=coexist side=wayland action=observe-mirror mimes=9 ← 只观察卫星镜像
event=coexist side=x11 action=observe-wm-claim           ← 卫星的 claim 不回环
reason=other-bridge-acted  ×10                           ← 卫星出手时主动让位
```

~90 次复制 → 89 次 claim，无 ownership 乒乓。

## 修复后回归结果

```text
1  W->X 文本                PASS
2  X->W 文本                PASS
3  W->X 图片 1.48MB (INCR)  PASS  sha256 字节一致，不卡死
4  X->W 图片                PASS  sha256 字节一致
5  X->W 富文本              PASS  text/html + text/plain 都保留，HTML 载荷完整
6  W->X 富文本              PASS  TARGETS 含 text/html，载荷完整
7  text/uri-list            PASS  自动翻译出 x-special/gnome-copied-files
8  大图流量后 TARGETS        PASS  秒回，无 wedge
9  W->X PRIMARY             PASS  （修复前为空）
10 X->W PRIMARY             PASS  （修复前为旧值）

40× 交替 + 10× 大图往返    40/40、20/20
RSS                        ~7–11 MB 平稳
error/warn                 0 error；仅启动瞬间 2 条 reason=empty-source
```

最终生产的真实流量印证了"全部 target 无差别透传"——Chromium 的私有类型
原样出现在 X11 侧：

```text
Wayland CLIPBOARD: text/plain … chromium/x-internal-source-rfh-token  chromium/x-source-url
X11     CLIPBOARD: TARGETS TIMESTAMP UTF8_STRING … chromium/x-internal-source-rfh-token  chromium/x-source-url
```

## 复现要点（给别人排查用）

```bash
# 1. X11 selector 是否还有人持、是否应答
python3 -c "
import ctypes
x=ctypes.CDLL('libX11.so.6'); x.XOpenDisplay.restype=ctypes.c_void_p
d=x.XOpenDisplay(b':0')
x.XInternAtom.restype=ctypes.c_ulong; x.XInternAtom.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int]
x.XGetSelectionOwner.restype=ctypes.c_ulong; x.XGetSelectionOwner.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
print(hex(x.XGetSelectionOwner(d,x.XInternAtom(d,b'CLIPBOARD',0))))"
DISPLAY=:0 timeout 5 xclip -selection clipboard -t TARGETS -o   # 卡住 = wedge

# 2. 有几个桥在抢
ps -eo pid,ppid,args | grep -E 'clipsync|xclip|clipnotify|wl-paste|clipferry'

# 3. 卫星自己的日志
journalctl --user -b | grep -iE 'satellite.*(selection|clipboard|incr)'
```

## 参考

- `Supreeeme/xwayland-satellite` — `ARCHITECTURE.md`、`src/xstate/selection.rs`、issues #91 / #433 / #485
- `jmylchreest/clipferry` — `DESIGN.md` §4.2（W→X 必须 eager 抓取）、§4.3（按身份防回环）、§10.1（与卫星共存）
- `astrand/xclip` issue #43 — 大 buffer / INCR 缺陷
- Mozilla bug 1942284 — Niri 下复制图片导致 hang
