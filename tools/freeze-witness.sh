#!/usr/bin/env bash
# ============================================================================
# freeze-witness —— 机器"假死"现场取证器
#
# 用途：卡死往往几秒就过去、或必须杀进程才能恢复，事后从日志里什么也看不到。
#       这个脚本常驻采样，把"卡死那一刻"的关键证据落盘。
#
#   freeze-witness start [interval]   # 后台常驻（默认 5s 一次轻量采样）
#   freeze-witness stop
#   freeze-witness status
#   freeze-witness dump [tag]         # 立刻抓一次深度快照（卡住时手动跑）
#   freeze-witness tail [n]           # 看最近采样
#   freeze-witness dumps              # 列出已抓到的快照
#
# 轻量采样每次只读 /proc 与 /sys；检测到 D 状态任务或 PSI 全停等 >50% 时
# 自动落一次深度快照（最多 30s 一次，避免刷屏）。
#
# 输出： ${XDG_STATE_HOME:-~/.local/state}/freeze-witness/
#          witness.log        滚动采样日志（超 20MB 轮转）
#          dumps/*.txt        深度快照
#
# 装到 PATH： install -Dm755 tools/freeze-witness.sh ~/.local/bin/freeze-witness
# ============================================================================
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/freeze-witness"
LOG="$STATE_DIR/witness.log"
DUMP_DIR="$STATE_DIR/dumps"
PIDFILE="$STATE_DIR/witness.pid"

# 关注的进程（按 comm/cmdline 匹配，ERE）。用 | 分隔，可用环境变量覆盖。
WATCH_PATTERNS="${FREEZE_WITNESS_WATCH:-wechat|WeChatAppEx|RadiumWMPF|qq|linuxqq|msedge|electron|ghostty|Xwayland|xwayland-satellite|niri|fcitx5|next-server}"
TOP_CPU_N=8
MAX_LOG_BYTES=$((20 * 1024 * 1024))

mkdir -p "$STATE_DIR" "$DUMP_DIR"

psi() { # psi <io|memory|cpu> <some|full>  -> avg10 数值
  awk -v k="$2" '$1==k {for(i=1;i<=NF;i++) if ($i ~ /^avg10=/){sub(/avg10=/,"",$i); print $i}}' \
      "/proc/pressure/$1" 2>/dev/null
}

dstate_tasks() { # 输出 "<pid> <comm> <wchan>"
  local p st
  for p in /proc/[0-9]*; do
    st=$(awk '{print $3}' "$p/stat" 2>/dev/null) || continue
    case "$st" in
      D*) printf '%s %s %s\n' "${p#/proc/}" "$(cat "$p/comm" 2>/dev/null)" "$(cat "$p/wchan" 2>/dev/null)";;
    esac
  done
}

thread_hist() { # thread_hist <pid>  -> "count wchan" 排序
  local pid=$1
  [ -d "/proc/$pid/task" ] || return 0
  find "/proc/$pid/task" -mindepth 1 -maxdepth 1 2>/dev/null | while read -r t; do
    cat "$t/wchan" 2>/dev/null && echo
  done | sed 's/^$/none/' | sort | uniq -c | sort -rn | head -6
}

proc_table() { # 匹配 WATCH_PATTERNS 的进程概要
  local pids
  pids=$(pgrep -f "$WATCH_PATTERNS" 2>/dev/null | tr '\n' ',')
  pids="${pids%,}"
  [ -n "$pids" ] || return 0
  ps -o pid,ppid,stat,%cpu,%mem,rss,etime,comm --no-headers \
     -p "$pids" 2>/dev/null | head -40
}

dump_disk_stats() {
  find /sys/block -maxdepth 2 -name stat -path '*nvme*' 2>/dev/null | while read -r d; do
    [ -r "$d" ] || continue
    printf '%s: %s\n' "$(basename "$(dirname "$d")")" "$(cat "$d")"
  done
}

dump_watched_threads() {
  pgrep -f "$WATCH_PATTERNS" 2>/dev/null | head -12 | while read -r pid; do
    printf '== pid=%s %s  threads=%s\n' \
      "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null)" \
      "$(find "/proc/$pid/task" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    thread_hist "$pid" | sed 's/^/     /'
  done
}

dump_gpu() {
  for g in /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -r "$g" ] && echo "$g = $(cat "$g" 2>/dev/null)"
  done
  echo "i915 相关 D 状态任务: $(dstate_tasks | grep -c i915)"
}

deep_dump() { # deep_dump <tag> -> 输出快照文件路径
  local tag="${1:-auto}" ts f d
  ts=$(date '+%Y%m%d-%H%M%S')
  f="$DUMP_DIR/${ts}-${tag}.txt"
  {
    echo "================ FREEZE WITNESS DUMP  tag=$tag ================"
    echo "time      : $(date '+%F %T %z')"
    echo "uptime    : $(uptime)"
    echo "kernel    : $(uname -r)"
    echo
    echo "---- 内存 / swap ----"
    free -h
    echo "swappiness: $(cat /proc/sys/vm/swappiness)"
    grep -E '^(pgscan_kswapd|pgsteal_kswapd|pswpin|pswpout|pgmajfault|nr_free_pages) ' /proc/vmstat
    echo
    echo "---- PSI 压力 ----"
    for r in io memory cpu; do
      echo "[$r] $(tr '\n' ' ' < "/proc/pressure/$r" 2>/dev/null)"
    done
    echo
    echo "---- 磁盘 ----"
    df -h | grep -vE 'tmpfs|efivarfs|overlay|credentials'
    dump_disk_stats
    echo
    echo "---- D 状态（不可中断等待）任务 ----"
    d=$(dstate_tasks)
    if [ -n "$d" ]; then
      echo "$d"
      echo "---- 各自的 kernel stack ----"
      while read -r pid comm wchan; do
        echo "== pid=$pid comm=$comm wchan=$wchan"
        sudo -n cat "/proc/$pid/stack" 2>/dev/null | sed 's/^/   /' \
          || echo "   (无权限或已退出)"
      done <<< "$d"
    else
      echo "(无)"
    fi
    echo
    echo "---- 关注进程 ----"
    proc_table
    echo
    echo "---- 关注进程的线程 wchan 分布 ----"
    dump_watched_threads
    echo
    echo "---- CPU 占用 Top ----"
    ps -eo pid,ppid,stat,%cpu,%mem,rss,etime,comm --no-headers --sort=-%cpu | head -"$TOP_CPU_N"
    echo
    echo "---- GPU 状态（若有）----"
    dump_gpu
    echo
    echo "---- 最近内核告警 ----"
    sudo -n dmesg -T --level=err,warn 2>/dev/null | tail -25 || echo "(无权限)"
    echo
    echo "---- 关注应用与合成器最近的告警日志 ----"
    journalctl --user --since "2 minutes ago" --no-pager 2>/dev/null \
      | grep -iE "$WATCH_PATTERNS" \
      | grep -iE 'error|warn|fail|timeout|block|hang|unresponsive|selection' | tail -30 \
      || echo "(无)"
  } > "$f" 2>&1
  printf '%s\n' "$f"
}

light_line() {
  local load mem swap d n top
  load=$(cut -d' ' -f1-3 /proc/loadavg)
  mem=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
  swap=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{printf "%.1f", (t-f)/1048576}' /proc/meminfo)
  d=$(dstate_tasks)
  n=$(printf '%s' "$d" | grep -c .)
  top=$(ps -eo %cpu,comm --no-headers --sort=-%cpu 2>/dev/null | head -3 \
        | awk '{printf "%s:%.0f%% ", $2, $1}')
  printf '%s load=%s avail=%sGi swap=%sGi D=%s psi_io=%s/%s psi_mem=%s/%s top=[%s]\n' \
    "$(date '+%F %T')" "$load" "$mem" "$swap" "$n" \
    "$(psi io some)" "$(psi io full)" "$(psi memory some)" "$(psi memory full)" "$top"
}

rotate_log() {
  local sz
  sz=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null
  fi
}

cmd_start() {
  local interval="${1:-5}"
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "已经在运行 (pid $(cat "$PIDFILE"))"
    return 0
  fi
  setsid --fork "$0" --loop "$interval" </dev/null >>"$LOG" 2>&1 &
  sleep 0.8
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "已启动 (pid $(cat "$PIDFILE"), interval=${interval}s)  日志: $LOG"
  else
    echo "启动失败，见 $LOG" >&2
    return 1
  fi
}

cmd_loop() {
  local interval="${1:-5}" last_dump=0 now d psi_full
  echo $$ > "$PIDFILE"
  trap 'rm -f "$PIDFILE"; exit 0' TERM INT
  echo "# freeze-witness 启动 pid=$$ interval=${interval}s watch=$WATCH_PATTERNS" >> "$LOG"
  while :; do
    rotate_log
    light_line >> "$LOG"
    now=$(date +%s)
    d=$(dstate_tasks)
    psi_full=$(psi io full)
    if { [ -n "$d" ] || awk -v v="${psi_full:-0}" 'BEGIN{exit !(v>50)}'; } \
       && [ $((now - last_dump)) -ge 30 ]; then
      last_dump=$now
      echo "  -> 触发深度快照" >> "$LOG"
      deep_dump "auto" >> "$LOG"
    fi
    sleep "$interval"
  done
}

cmd_stop() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null && echo "已停止 (pid $(cat "$PIDFILE"))"
    rm -f "$PIDFILE"
  else
    pkill -f "$0 --loop" 2>/dev/null && echo "已停止" || echo "没在运行"
  fi
}

cmd_status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "运行中 pid=$(cat "$PIDFILE")"
  else
    echo "未运行"
  fi
  echo "状态目录: $STATE_DIR"
  [ -f "$LOG" ] && echo "采样条数: $(wc -l < "$LOG")  大小: $(du -h "$LOG" | cut -f1)"
  echo "快照数: $(find "$DUMP_DIR" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l)"
}

case "${1:-status}" in
  --loop)  shift; cmd_loop "$@" ;;
  start)   shift; cmd_start "$@" ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  dump)    shift; echo "已写入: $(deep_dump "${1:-manual}")" ;;
  tail)    tail -n "${2:-30}" "$LOG" ;;
  dumps)   find "$DUMP_DIR" -maxdepth 1 -name '*.txt' -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null \
             | sort -r | head -20 ;;
  *)       sed -n '2,24p' "$0"; exit 2 ;;
esac
