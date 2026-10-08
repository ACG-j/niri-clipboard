#!/usr/bin/env bash
# ============================================================================
# clipboard-owner-watch —— 找出"谁是坏的 X11 CLIPBOARD owner"
#
# 背景（2026-10-08 实测）：
#   某个 X11 客户端会抢占 CLIPBOARD，TARGETS 秒回，但**任何取数据请求都不应答**，
#   请求方（xclip/GTK/Qt/Electron/ToDesk）会阻塞约 5 秒后拿到空数据。
#   微信/QQ 都是 X11 客户端 → 每次碰剪贴板都卡 5 秒 → 表现为"窗口假死"。
#
#   已证明排除：clipferry 运行与停止时现象完全一致；Xwayland/卫星自身提供的
#   owner 读取只需 3–5 ms。所以问题只跟随那一个客户端。
#
# 本脚本做两件事：
#   1. 轮询 CLIPBOARD owner，记录每次变化（时间、owner id、读取延迟、是否"坏"）
#   2. 把一个 owner id 与"当时哪个应用在前台/刚刚聚焦"关联起来
#
# 用法：
#   clipboard-owner-watch.sh start     # 后台开始记录（默认每 0.3s 探一次）
#   clipboard-owner-watch.sh stop
#   clipboard-owner-watch.sh show      # 打印记录
#   clipboard-owner-watch.sh mark <名字>   # 打一个标记（例如 "我要在微信里复制了"）
#
# 典型流程：start → 在微信里复制一段文字 → sleep 3 → 在 QQ 里复制 → ...
#           最后 show，就能看出"哪个操作产生 0x5000001"。
# ============================================================================
set -uo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/clipboard-owner-watch"
LOG="$STATE/watch.log"
PIDFILE="$STATE/watch.pid"
export DISPLAY="${DISPLAY:-:0}"

mkdir -p "$STATE"

owner_and_latency() { # 输出 "<owner-hex> <延迟ms> <内容长度>"
  python3 - <<'PY'
import ctypes, subprocess, time, os
x = ctypes.CDLL("libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p
d = x.XOpenDisplay(os.environ.get("DISPLAY", ":0").encode())
if not d:
    print("no-display 0 0"); raise SystemExit
x.XInternAtom.restype = ctypes.c_ulong
x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XGetSelectionOwner.restype = ctypes.c_ulong
x.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
o = x.XGetSelectionOwner(d, x.XInternAtom(d, b"CLIPBOARD", 0))
t0 = time.time()
try:
    out = subprocess.run(["xclip", "-sel", "clip", "-o"], capture_output=True, timeout=8)
    n = len(out.stdout)
except Exception:
    n = -1
ms = int((time.time() - t0) * 1000)
print(f"0x{o:x} {ms} {n}")
PY
}

loop() {
  echo $$ > "$PIDFILE"
  trap 'rm -f "$PIDFILE"; exit 0' TERM INT
  local last="" line o ms n
  echo "# $(date '+%F %T') 开始监听" >> "$LOG"
  while :; do
    line=$(owner_and_latency)
    o=${line%% *}
    ms=$(echo "$line" | awk '{print $2}')
    n=$(echo "$line" | awk '{print $3}')
    if [ "$o" != "$last" ]; then
      local verdict="ok"
      [ "${ms:-0}" -gt 1000 ] && verdict="⚠️ 慢(不应答)"
      printf '%s owner=%s read=%sms len=%s %s\n' "$(date '+%F %T')" "$o" "$ms" "$n" "$verdict" >> "$LOG"
      last="$o"
    fi
    sleep 0.3
  done
}

case "${1:-show}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "已在运行 (pid $(cat "$PIDFILE"))"; exit 0
    fi
    setsid --fork "$0" --loop </dev/null >>"$LOG" 2>&1 &
    sleep 0.8
    echo "已启动。日志: $LOG"
    ;;
  --loop) loop ;;
  stop)   [ -f "$PIDFILE" ] && { kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; echo 已停止; } || echo 未运行 ;;
  mark)   shift; echo "=== MARK: $* ($(date '+%F %T')) ===" >> "$LOG"; echo "已打标记: $*" ;;
  show)   [ -f "$LOG" ] && cat "$LOG" || echo "(无记录)" ;;
  *)      sed -n '2,26p' "$0" ;;
esac
