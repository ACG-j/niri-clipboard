#!/usr/bin/env bash
# ============================================================================
# niri-clipboard installer
#
#   ./install.sh            # 幂等安装/更新
#   ./install.sh --no-niri  # 不动 niri 配置，只装 drop-in + 服务
#   ./install.sh --verify   # 装完顺手跑一遍回归
#
# 做的事：
#   1. 检查环境（niri 会话 / clipferry / wl-clipboard）
#   2. 安装 systemd drop-in  -> ~/.config/systemd/user/clipferry.service.d/
#   3. 幂等地处理 niri 配置  -> 注释掉 spawn-at-startup "clipsync"，插入托管标记块
#   4. enable --now clipferry.service
#
# 幂等：托管块已存在则不重复插入；niri 配置无需改动时**不会**产生备份文件。
# ============================================================================
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
NIRI="$CFG/niri/config.kdl"
DROPIN_DIR="$CFG/systemd/user/clipferry.service.d"

DO_NIRI=1
DO_VERIFY=0
for a in "$@"; do
  case "$a" in
    --no-niri) DO_NIRI=0 ;;
    --verify)  DO_VERIFY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. 环境检查 ------------------------------------------------------------
[ -n "${WAYLAND_DISPLAY:-}" ] || warn "WAYLAND_DISPLAY 未设置 —— 请在 niri 会话里运行本脚本"
if ! command -v clipferry >/dev/null 2>&1; then
  die "未安装 clipferry。先装：
       paru -S clipferry
     或
       cargo install --git https://github.com/jmylchreest/clipferry"
fi
command -v wl-copy >/dev/null 2>&1 || die "缺少 wl-clipboard（pacman -S wl-clipboard）"
command -v xclip  >/dev/null 2>&1 || warn "缺少 xclip：只影响验证脚本，不影响 clipferry 运行"
if command -v clipsync >/dev/null 2>&1; then
  warn "系统里还装着 clipsync。它与 xwayland-satellite 会抢 X11 CLIPBOARD，建议卸载：
       sudo pacman -Rns clipsync-git"
fi
log "clipferry: $(clipferry --version)"

# --- 2. systemd drop-in -----------------------------------------------------
log "安装 drop-in -> $DROPIN_DIR/eager-size.conf"
mkdir -p "$DROPIN_DIR"
install -Dm644 "$ROOT/config/systemd/clipferry.service.d/eager-size.conf" \
                "$DROPIN_DIR/eager-size.conf"

# --- 3. niri 配置 -----------------------------------------------------------
if [ "$DO_NIRI" = 1 ] && [ -f "$NIRI" ]; then
  backup="$NIRI.before-niri-clipboard-$(date +%Y%m%d%H%M%S)"
  # python 决定是否需要改动；只有真要改才写备份，避免每次空跑都堆一个备份文件。
  if python3 - "$NIRI" "$backup" <<'PY'
import os, shutil, sys

path, backup = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    original = f.read()
lines = original.splitlines(keepends=True)

already = any("niri-clipboard (managed by" in l for l in lines)

BLOCK = [
    "// >>> niri-clipboard (managed by ~/Projects/niri-clipboard) >>>\n",
    "// 这里不要 spawn 任何 X11<->Wayland 剪切板桥。\n",
    "// clipferry 由 systemd user 服务管理（graphical-session.target）。\n",
    "// 原因见 ~/Projects/niri-clipboard/README.md\n",
    "// <<< niri-clipboard <<<\n",
]

out, commented = [], 0
for l in lines:
    s = l.strip()
    if s.startswith("spawn-at-startup") and "clipsync" in s and not s.startswith("//"):
        out.append("//" + l)
        commented += 1
    else:
        out.append(l)

if not already:
    # 插到最后一个 clipsync 行之后；否则插到 dms 启动行之后；再否则插到文件头
    idx = None
    for i, l in enumerate(out):
        if "clipsync" in l:
            idx = i
    if idx is None:
        for i, l in enumerate(out):
            if 'spawn-at-startup "dms"' in l:
                idx = i
    if idx is None:
        out = BLOCK + out
    else:
        out[idx + 1:idx + 1] = BLOCK

modified = "".join(out)
if modified == original:
    print("  niri 配置已是目标状态，无需改动（不生成备份）")
    sys.exit(0)

shutil.copy2(path, backup)
with open(path, "w", encoding="utf-8") as f:
    f.write(modified)
print(f"  niri 配置：注释 clipsync 启动项 {commented} 处"
      + ("，托管块已存在" if already else "，已插入托管块")
      + f"；备份 -> {os.path.basename(backup)}")
PY
  then
    if command -v niri >/dev/null 2>&1; then
      if niri validate -c "$NIRI" >/dev/null 2>&1; then
        log "niri 配置校验通过"
      else
        die "niri 配置校验失败！已备份在 $backup，请先还原"
      fi
    fi
  else
    die "处理 niri 配置失败（$NIRI）"
  fi
else
  if [ "$DO_NIRI" = 1 ]; then
    warn "没找到 $NIRI，跳过 niri 配置处理"
  else
    log "--no-niri：跳过 niri 配置"
  fi
fi

# --- 4. 服务 ----------------------------------------------------------------
log "重载 systemd 并启用 clipferry.service"
systemctl --user daemon-reload
systemctl --user enable --now clipferry.service
sleep 1.5
systemctl --user --no-pager status clipferry.service | sed -n '1,12p'

# --- 5. 可选验证 ------------------------------------------------------------
if [ "$DO_VERIFY" = 1 ]; then
  log "运行回归验证"
  "$ROOT/tools/clip-verify.sh" --primary
fi

log "完成。日志： journalctl --user -u clipferry.service -f"
