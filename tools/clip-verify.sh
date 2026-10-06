#!/usr/bin/env bash
# ============================================================================
# X11 <-> Wayland 剪切板桥的完整回归矩阵
#
#   ./clip-verify.sh                      # 默认测试集
#   ./clip-verify.sh --primary            # 追加 PRIMARY（中键）测试
#   ./clip-verify.sh --png /path/to.png   # 指定测试图（默认挑最大的截图）
#
# 测试项（CLIPBOARD，双向）：
#   1 W->X 文本            2 X->W 文本
#   3 W->X 图片(INCR)      4 X->W 图片
#   5 X->W 富文本多target   6 W->X 富文本
#   7 text/uri-list        8 死锁自检（大图流量后 TARGETS 是否仍秒回）
#   9 (--primary) W->X 中键  10 (--primary) X->W 中键
#
# 依赖：wl-clipboard, xclip, python3(ctypes, 查 X11 selection owner)
#       cc + libX11 头文件（用于编译 clip-multi）
#
# 退出码：0 = 全部通过，1 = 有失败
# ============================================================================
set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
D="${DISPLAY:-:0}"
WD="${WAYLAND_DISPLAY:-wayland-1}"
export DISPLAY="$D" WAYLAND_DISPLAY="$WD"

WITH_PRIMARY=0
PNG_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --primary) WITH_PRIMARY=1; shift ;;
    --png)     PNG_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- 依赖检查 ---------------------------------------------------------------
for c in wl-copy wl-paste xclip python3 sha256sum; do
  if ! command -v "$c" >/dev/null; then echo "missing dependency: $c" >&2; exit 2; fi
done

MULTI="$SELF_DIR/clip-multi"
if [ ! -x "$MULTI" ]; then
  echo "[build] clip-multi ..."
  if ! ( cd "$SELF_DIR" && ${CC:-cc} -O2 -o clip-multi clip-multi.c -lX11 ); then
    echo "failed to build clip-multi (need libX11 headers)" >&2
    exit 2
  fi
fi

WORK=$(mktemp -d /tmp/clip-verify.XXXXXX)
cleanup() { pkill -x clip-multi 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# --- 测试图：>256KB 才会让 X11 侧走 INCR（也就是当年卡死的那条路径） --------
PNG="$WORK/test.png"
if [ -n "$PNG_OVERRIDE" ] && [ -f "$PNG_OVERRIDE" ]; then
  cp "$PNG_OVERRIDE" "$PNG"
else
  src=$(find "$HOME/Pictures/Screenshots/Niri-screenshots" -maxdepth 1 -name '*.png' \
        -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2-)
  if [ -n "$src" ]; then
    cp "$src" "$PNG"
  elif ! magick -size 1600x1200 plasma: "$PNG" 2>/dev/null; then
    echo "no test png available; pass --png" >&2
    exit 2
  fi
fi
WANT_PNG=$(sha256sum "$PNG" | cut -d' ' -f1)
PNG_SIZE=$(stat -c%s "$PNG")

# --- 断言原语 ---------------------------------------------------------------
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# 用 if/else 而不是 `A && ok || bad`：后者在 A 为真但 ok 失败时会误跑 bad
# （SC2015），断言层出错会静默变成假阳性。
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: want '$2' got '$1'"; fi; }
has()   { if printf '%s\n' "$1" | grep -qxF -- "$2"; then ok "$3"
          else bad "$3: '$2' missing from [$1]"; fi; }
hasre() { if printf '%s\n' "$1" | grep -qE -- "$2"; then ok "$3"
          else bad "$3: /$2/ not found in [$1]"; fi; }
sha_eq(){ if [ "$1" = "$WANT_PNG" ]; then ok "$2"
          else bad "$2 (sha ${1:0:16} vs ${WANT_PNG:0:16})"; fi; }
runs()  { local label=$1; shift
          if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }

# wl-copy / xclip -i 会 fork 出后台进程，持续持有继承来的 stdout。
# 如果调用者把本脚本的输出接进管道（`| tee`、`| tail`、日志收集），
# 那个管道就永远等不到 EOF —— 整条流水线挂死（astrand/xclip#134）。
# 所以所有“写剪贴板 / 占位”的调用都必须让子进程脱离调用者的 fd。
own() { "$@" >/dev/null 2>&1; }

owner_of() { # $1 = selection name
  python3 -c "
import ctypes
x=ctypes.CDLL('libX11.so.6'); x.XOpenDisplay.restype=ctypes.c_void_p
d=x.XOpenDisplay(b'$D')
x.XInternAtom.restype=ctypes.c_ulong
x.XInternAtom.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int]
x.XGetSelectionOwner.restype=ctypes.c_ulong
x.XGetSelectionOwner.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
print(hex(x.XGetSelectionOwner(d,x.XInternAtom(d,b'$1',0))))"
}

echo "=================================================================="
echo " clipboard verification   DISPLAY=$D  WAYLAND_DISPLAY=$WD"
echo " test png: ${PNG_SIZE} bytes   primary=${WITH_PRIMARY}"
echo "=================================================================="

# ---------- 1. Wayland -> X11 文本 ----------
echo "[1] Wayland -> X11  text"
T=$(printf 'T-W2X-%s' "$RANDOM"); own wl-copy "$T"; sleep 1.2
eq "$(xclip -sel clip -o 2>/dev/null)" "$T" "text W->X"

# ---------- 2. X11 -> Wayland 文本 ----------
echo "[2] X11 -> Wayland  text"
T=$(printf 'T-X2W-%s' "$RANDOM")
printf '%s' "$T" | own xclip -sel clip -i -t UTF8_STRING; sleep 1.2
eq "$(wl-paste -n -t UTF8_STRING 2>/dev/null || wl-paste -n 2>/dev/null)" "$T" "text X->W"

# ---------- 3. Wayland -> X11 图片 ----------
echo "[3] Wayland -> X11  image/png (${PNG_SIZE}B, forces INCR)"
own wl-copy -t image/png < "$PNG"; sleep 2
echo "      X11 CLIPBOARD owner: $(owner_of CLIPBOARD)"
sha_eq "$(xclip -sel clip -o -t image/png 2>/dev/null | sha256sum | cut -d' ' -f1)" \
       "image/png W->X byte-identical"
echo "      X11 TARGETS: $(xclip -sel clip -t TARGETS -o 2>&1 | tr '\n' ' ')"

# ---------- 4. X11 -> Wayland 图片 ----------
echo "[4] X11 -> Wayland  image/png"
own xclip -sel clip -i -t image/png < "$PNG"; sleep 2
sha_eq "$(wl-paste -t image/png 2>/dev/null | sha256sum | cut -d' ' -f1)" \
       "image/png X->W byte-identical"

# ---------- 5. X11 -> Wayland 富文本（多 target owner） ----------
echo "[5] X11 -> Wayland  rich text (text/html + text/plain, multi-target owner)"
pkill -x clip-multi 2>/dev/null; sleep 0.3
"$MULTI" > "$WORK/multi.log" 2>&1 & sleep 1.5
TYPES=$(wl-paste --list-types 2>/dev/null | tr '\n' ' ')
echo "      Wayland offer types: $TYPES"
hasre "$TYPES" '(^| )text/html( |$)'  "text/html survived X11 -> Wayland"
hasre "$TYPES" '(^| )text/plain( |$)' "text/plain survived X11 -> Wayland"
eq "$(wl-paste -t text/html 2>/dev/null)" '<b>multi-html-HTML</b>' "html payload X->W"

# ---------- 6. Wayland -> X11 富文本 ----------
echo "[6] Wayland -> X11  rich text (text/html)"
own wl-copy -t text/html '<b>w2x-html</b>'; sleep 2
TGT=$(xclip -sel clip -t TARGETS -o 2>&1 | tr '\n' ' ')
echo "      X11 TARGETS: $TGT"
hasre "$TGT" '(^| )text/html( |$)' "text/html reached X11 TARGETS"
eq "$(xclip -sel clip -o -t text/html 2>/dev/null)" '<b>w2x-html</b>' "html payload W->X"

# ---------- 7. text/uri-list ----------
echo "[7] text/uri-list (file copy)"
printf 'hi\n' > "$WORK/a.txt"
printf 'file://%s\r\n' "$WORK/a.txt" | own wl-copy -t text/uri-list; sleep 2
hasre "$(xclip -sel clip -t TARGETS -o 2>&1 | tr '\n' ' ')" \
      'text/uri-list|x-special/gnome-copied-files' "uri-list target on X11"

# ---------- 8. 死锁自检 ----------
echo "[8] deadlock check: X11 TARGETS still answers after image traffic"
runs "X11 TARGETS answered quickly (no wedge)" \
     timeout 5 xclip -sel clip -t TARGETS -o

# ---------- 9/10. PRIMARY ----------
if [ "$WITH_PRIMARY" = 1 ]; then
  echo "[9] Wayland PRIMARY -> X11 PRIMARY"
  T=$(printf 'P-W2X-%s' "$RANDOM"); own wl-copy -p "$T"; sleep 1.5
  eq "$(xclip -selection primary -o 2>/dev/null)" "$T" "primary W->X"

  echo "[10] X11 PRIMARY -> Wayland PRIMARY"
  T=$(printf 'P-X2W-%s' "$RANDOM")
  printf '%s' "$T" | own xclip -selection primary -i -t UTF8_STRING; sleep 1.5
  eq "$(wl-paste -p -n 2>/dev/null)" "$T" "primary X->W"
fi

echo "------------------------------------------------------------------"
echo " RESULT: $pass passed, $fail failed"
echo "------------------------------------------------------------------"
[ "$fail" -eq 0 ]
