#!/usr/bin/env bash
# ============================================================================
# niri-clipboard uninstaller
#
#   ./uninstall.sh              # 停服务、删 drop-in、还原 niri 配置
#   ./uninstall.sh --keep-niri  # 保留 niri 配置不动
#
# 注意：不会卸载 clipferry 包本身（那是 pacman 的职责）。
#       要卸： sudo pacman -Rns clipferry
# ============================================================================
set -euo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
NIRI="$CFG/niri/config.kdl"
DROPIN_DIR="$CFG/systemd/user/clipferry.service.d"

DO_NIRI=1
for a in "$@"; do
  case "$a" in
    --keep-niri) DO_NIRI=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

# --- 1. 服务 -----------------------------------------------------------------
log "停用 clipferry.service"
systemctl --user disable --now clipferry.service 2>/dev/null || warn "服务本来就没在跑"
log "删除 drop-in -> $DROPIN_DIR"
rm -fv "$DROPIN_DIR/eager-size.conf"
rmdir "$DROPIN_DIR" 2>/dev/null || true
systemctl --user daemon-reload

# --- 2. niri 配置还原 --------------------------------------------------------
if [ "$DO_NIRI" = 1 ] && [ -f "$NIRI" ]; then
  python3 - "$NIRI" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
out, skipped = [], False
for l in lines:
    if "niri-clipboard (managed by" in l:
        skipped = True
        continue
    if "niri-clipboard <<<" in l:
        skipped = False
        continue
    if skipped:
        continue          # 丢弃托管块内部
    out.append(l)
open(path, "w", encoding="utf-8").writelines(out)
print("  niri 配置：已移除托管标记块（保留 //spawn-at-startup \"clipsync\" 注释）")
PY
  if command -v niri >/dev/null 2>&1; then
    if niri validate -c "$NIRI" >/dev/null 2>&1; then
      log "niri 配置校验通过"
    else
      warn "niri 配置校验失败，请检查 $NIRI"
    fi
  fi
  warn "若要恢复旧版 clipsync 行为：取消注释 spawn-at-startup \"clipsync\" 并重装 clipsync-git"
else
  log "跳过 niri 配置处理"
fi

log "完成。clipferry 包仍在： sudo pacman -Rns clipferry"
