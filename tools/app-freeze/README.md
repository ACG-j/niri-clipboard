# app-freeze —— 微信 / QQ「窗口假死」的 A/B 实验启动器

> 这一节与剪切板无关。放在同一仓库是因为它源自同一次排查，
> 且共用 `../freeze-witness.sh` 取证。

## 背景

实测系统层面全部干净（CPU PSI full=0.00%、内存 0.05%、磁盘空闲、
无 OOM/段错误/文件系统错误），所以假死几乎肯定是**应用侧**的。
外部资料指向两类已知问题：

| 方向 | 依据 |
| --- | --- |
| **fcitx5 输入法与 Qt/Electron 的同步调用** | Arch 中文 wiki 指出 `wechat-bin 4.1.13.x` 需 `QT_IM_MODULE=text-input-unstable-v3`；`QT_IM_MODULE=fcitx` 下微信不复用 popup 而是反复新建（[论坛](https://forum.archlinuxcn.org/t/topic/17365)）；fcitx5-qt 有 [Telegram 冻结 #47](https://github.com/fcitx/fcitx5-qt/issues/47)、[Qt 6.10 冲突 #77](https://github.com/fcitx/fcitx5-qt/issues/77) |
| **Electron 在 niri 上的 GPU 合成** | [niri #3777](https://github.com/niri-wm/niri/discussions/3777)：Electron 应用闪屏/卡顿，`--disable-gpu-compositing` 可解；AUR `linuxqq` 评论区大量"QQ 卡死后拖垮任务栏/通知 + libnotify 超时" |

当前这台机器的启动参数（可疑点已标注）：

```text
wechat : QT_QPA_PLATFORM=xcb QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx FCITX_QT_USE_SYNC=1
                                                                                          ^^^^^^^^^^^^^^^^^^^
         xcb 后端 + 同步 IM => 每次按键都在 UI 线程上做阻塞式 DBus 往返
qq     : ELECTRON_OZONE_PLATFORM_HINT=wayland DESKTOPINTEGRATION=false /usr/bin/linuxqq --no-sandbox
         没有 --enable-wayland-ime，也没有 GPU 合成相关开关
```

## 三个变体

| 启动器 | 改变了什么 | 检验的假设 |
| --- | --- | --- |
| `wechat-nosync` | 去掉 `FCITX_QT_USE_SYNC=1`，其余不变 | 同步 IM 阻塞 UI 线程 |
| `wechat-wayland` | 改走原生 Wayland + `QT_IM_MODULE=text-input-unstable-v3`（不再 xcb、不再 sync） | xcb 后端 + fcitx 插件路径是根因 |
| `qq-nogpucomp` | 加 `--disable-gpu-compositing` | Electron GPU 合成与 niri 不兼容 |

## 怎么用

一次只跑一个变体，**至少用一整天**（假死是间歇性的），期间让
freeze-witness 常驻：

```bash
install -Dm755 tools/app-freeze/wechat-nosync   ~/.local/bin/wechat-nosync
install -Dm755 tools/app-freeze/wechat-wayland  ~/.local/bin/wechat-wayland
install -Dm755 tools/app-freeze/qq-nogpucomp    ~/.local/bin/qq-nogpucomp

install -Dm755 tools/freeze-witness.sh ~/.local/bin/freeze-witness
freeze-witness start 3
```

先**完全退出**对应应用（微信要退托盘，不能只关窗口），再用变体启动：

```bash
pkill -f '/opt/wechat/wechat' ; wechat-nosync
pkill -f '/opt/wechat/wechat' ; wechat-wayland
pkill -f 'linuxqq'            ; qq-nogpucomp
```

卡住的那一瞬间也手动抓一份：

```bash
freeze-witness dump frozen
```

然后对比 `~/.local/state/freeze-witness/dumps/` 里"卡住时"和"正常时"的快照，
重点看：

- 关注进程的**线程 wchan 分布**（假死时主线程/渲染线程停在哪个内核函数）
- 全线程 D 状态及其内核栈
- CPU Top（是死锁在等，还是在忙转）

## 判定

| 观察 | 结论 |
| --- | --- |
| 换成某个变体后一整天不再假死 | 该变量即根因，把它固化进 `~/.local/share/applications/*.desktop` |
| 三个变体都还假死 | 排除这两类，转向 Electron 自身 / 内核 GPU 驱动方向 |
| 假死时快照显示某线程长期停在 `futex/do_epoll_wait` 且 CPU=0 | 是死锁（等对方），重点看该线程所属子系统 |
| 假死时某线程 CPU=100% | 是忙等/渲染卡死，走 GPU 方向 |

配好后记得把结论写回本文件的"结果"小节。

## 结果

<!-- 留空，等实验后填写 -->
