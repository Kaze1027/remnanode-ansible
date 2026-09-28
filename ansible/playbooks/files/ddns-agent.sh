#!/bin/bash
# ============================================================================
# ddns-agent —— 探测本机公网 IPv4 与【原生】IPv6，变化时签名上报到 ddns-hub
#
#   IPv4：外部回显（api.ipify.org → ifconfig.me → icanhazip.com）
#   IPv6：网卡 global 且 prefixlen≠128，排除 Aether 租约段 2600:1700:2bc1:409d::/48、
#         排除 deprecated/tentative 地址（即 VPS 自己的原生 IPv6）
#   防抖：连续两次探测一致才上报（首次部署立即上报）
# ============================================================================
set -uo pipefail

ENVF="${DDNS_ENV_FILE:-/etc/ddns-agent.env}"
# shellcheck disable=SC1090
[ -r "$ENVF" ] && . "$ENVF"

HOST="${DDNS_HOST:-}"
SECRET="${DDNS_SECRET:-}"
HUB="${DDNS_HUB_URL:-}"
IFACE="${DDNS_IFACE:-eth0}"
STATE_DIR=/var/lib/ddns-agent
STATE="$STATE_DIR/state.json"

log() { echo "[ddns-agent] $*"; }
if [ -z "$HOST" ] || [ -z "$SECRET" ] || [ -z "$HUB" ]; then
  log "缺少 DDNS_HOST / DDNS_SECRET / DDNS_HUB_URL，退出"
  exit 1
fi
mkdir -p "$STATE_DIR"

# ---------------- IPv4 ----------------
ip4=""
for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
  v=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ip4="$v"; break ;;
  esac
done

# ---------------- 原生 IPv6 ----------------
ip6=""
while read -r _ _ _ cidr rest; do
  addr="${cidr%%/*}"; plen="${cidr##*/}"
  [ "$plen" = "128" ] && continue
  case "$addr" in 2600:1700:2bc1:409d:*) continue ;; esac
  case "$rest" in *deprecated*|*tentative*) continue ;; esac
  ip6="$addr"; break
done < <(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null)

log "探测结果 ip4=${ip4:-none} ip6=${ip6:-none}"
if [ -z "$ip4" ] && [ -z "$ip6" ]; then
  log "无可用 IP，跳过本轮"
  exit 0
fi

# ---------------- 读取上次状态 ----------------
get() { [ -r "$STATE" ] && sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$STATE" || true; }
prev4=$(get prev4); prev6=$(get prev6); cand4=$(get cand4); cand6=$(get cand6)

# 无历史记录（首次部署）→ 立即上报；否则要求连续两次一致
if [ -n "$prev4$prev6" ]; then
  if [ "$ip4" != "$cand4" ] || [ "$ip6" != "$cand6" ]; then
    printf '{"prev4":"%s","prev6":"%s","cand4":"%s","cand6":"%s"}\n' "$prev4" "$prev6" "$ip4" "$ip6" > "$STATE"
    log "检测到变化，等待下一轮确认（cand ip4=$ip4 ip6=$ip6）"
    exit 0
  fi
  if [ "$ip4" = "$prev4" ] && [ "$ip6" = "$prev6" ]; then
    log "无变化"
    exit 0
  fi
fi

# ---------------- 签名并上报 ----------------
ts=$(date +%s)
sig=$(printf '%s\n%s\n%s\n%s' "$HOST" "$ip4" "$ip6" "$ts" \
      | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $NF}')
body=$(printf '{"host":"%s","ip4":"%s","ip6":"%s","ts":%s,"sig":"%s"}' \
       "$HOST" "$ip4" "$ip6" "$ts" "$sig")

resp=$(curl -fsS --max-time 20 -X POST "$HUB" -H 'Content-Type: application/json' -d "$body" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  log "上报失败(rc=$rc): ${resp:0:200}"
  exit 1
fi
log "上报成功: ${resp:0:300}"
printf '{"prev4":"%s","prev6":"%s","cand4":"%s","cand6":"%s","ts":%s}\n' \
  "$ip4" "$ip6" "$ip4" "$ip6" "$ts" > "$STATE"
