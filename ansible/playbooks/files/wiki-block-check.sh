#!/bin/bash
# ============================================================================
# wiki-block-check.sh —— 检测【当前出口 IP】是否被维基百科 / 维基媒体封禁
#
#   判定依据（维基官方 API，非页面文本抓取）：
#     1) 本地封禁：https://<wiki>/w/api.php?action=query&meta=userinfo&uiprop=blockinfo
#                  → blockid / blockedby / blockreason / blockexpiry / anononly / blockpartial
#     2) 全局封禁：https://meta.wikimedia.org/w/api.php?action=query&list=globalblocks&bgip=<IP>
#
#   依赖：curl、jq
#
# 用法：
#   ./wiki-block-check.sh                     # IPv4 + IPv6 出口都测（完整输出）
#   ./wiki-block-check.sh -4                  # 只测 IPv4
#   ./wiki-block-check.sh -6 --native         # 只测 IPv6，且绑定【原生 IPv6】出口
#   ./wiki-block-check.sh -i 2602:faa8::a     # 指定源地址
#   ./wiki-block-check.sh --json              # 输出 JSON（每族一行）
#   ./wiki-block-check.sh --block --tag "node-03 (us3.awso.cloud)"
#                                             # 只输出被封禁项（无封禁则无输出；给自动化汇总用）
#   ./wiki-block-check.sh -H "zh.wikipedia.org ja.wikipedia.org"
#
# 退出码：0=未被封禁  1=存在封禁  2=无法判定（网络/请求失败）
# ============================================================================
set -uo pipefail

WIKIS_DEFAULT="zh.wikipedia.org en.wikipedia.org"
META="meta.wikimedia.org"
UA="${WIKI_UA:-WikiBlockCheck/1.0 (IP quality self-check)}"
TIMEOUT="${WIKI_TIMEOUT:-10}"
CURL_BASE=(--noproxy '*' --max-time "$TIMEOUT" -A "$UA" -sS)

FAMILY=""
BIND=""
NATIVE=0
JSON=0
BLOCK_ONLY=0
TAG=""
WIKIS="$WIKIS_DEFAULT"

while [ $# -gt 0 ]; do
  case "$1" in
    -4) FAMILY=4 ;;
    -6) FAMILY=6 ;;
    -i) shift; BIND="${1:-}" ;;
    --native) NATIVE=1; FAMILY=6 ;;
    -H|--hosts) shift; WIKIS="${1:-}" ;;
    --json) JSON=1 ;;
    --block) BLOCK_ONLY=1 ;;
    --tag) shift; TAG="${1:-}" ;;
    -t|--timeout) shift; TIMEOUT="${1:-10}"; CURL_BASE=(--noproxy '*' --max-time "$TIMEOUT" -A "$UA" -sS) ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------- 原生 IPv6 自动识别（排除 Aether 租约段与 /128） ----------
if [ "$NATIVE" = 1 ] && [ -z "$BIND" ]; then
  IFACE="${WIKI_IFACE:-eth0}"
  while read -r _ _ _ cidr rest; do
    addr="${cidr%%/*}"; plen="${cidr##*/}"
    [ "$plen" = "128" ] && continue
    case "$addr" in 2600:1700:2bc1:409d:*) continue ;; esac
    case "$rest" in *deprecated*|*tentative*) continue ;; esac
    BIND="$addr"; break
  done < <(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null)
  [ -n "$BIND" ] || { echo "未找到原生 IPv6 地址（$IFACE）" >&2; exit 2; }
fi

fam_args() { if [ "$1" = "4" ]; then printf '%s\n' -4; else printf '%s\n' -6; fi; }

http_get() {  # $1=fam $2=bind $3=url... —— 3 次重试（维基 API 偶发超时/限流）
  local fam="$1" bind="$2"; shift 2
  local i=1 out="" extra=()
  [ -n "$bind" ] && extra=(--interface "$bind")
  while [ "$i" -le 3 ]; do
    out=$(curl "${CURL_BASE[@]}" $(fam_args "$fam") "${extra[@]}" "$@" 2>/dev/null)
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

api_userinfo() {  # $1=host $2=fam
  http_get "$2" "$BIND" \
    "https://$1/w/api.php?action=query&meta=userinfo&uiprop=blockinfo%7Crights&format=json&formatversion=2"
}

api_global() {  # $1=ip $2=fam
  http_get "$2" "$BIND" --get --data-urlencode "bgip=$1" \
    "https://$META/w/api.php?action=query&list=globalblocks&format=json&formatversion=2&bglimit=20"
}

HDR_PRINTED=0
print_header() { [ "$HDR_PRINTED" = 1 ] && return; [ -n "$TAG" ] && echo "▎$TAG"; HDR_PRINTED=1; }

# ---------- 单族检测 ----------
run_family() {  # $1=fam
  local fam="$1" ip="" js=""
  for w in $WIKIS; do
    js=$(api_userinfo "$w" "$fam") || continue
    ip=$(printf '%s' "$js" | jq -r '.query.userinfo.name // empty' 2>/dev/null)
    [ -n "$ip" ] && break
  done

  if [ -z "$ip" ]; then
    if [ "$JSON" = 1 ]; then
      printf '{"family":"v%s","ip":null,"error":"no_egress_or_api_failed"}\n' "$fam"
    elif [ "$BLOCK_ONLY" != 1 ]; then
      echo "出口 IPv$fam: ⚠️  无法取得出口 IP（无该族出口 / API 请求失败）"
    fi
    return 2
  fi

  local blocked=0 failed=0 results="" lines=()
  for w in $WIKIS; do
    local ujs; ujs=$(api_userinfo "$w" "$fam")
    if [ -z "$ujs" ]; then
      failed=1
      if [ "$BLOCK_ONLY" != 1 ]; then lines+=("  $w  ⚠️  请求失败"); fi
      results="${results}{\"wiki\":\"$w\",\"status\":\"error\"},"
      continue
    fi
    local bid by reason expiry anon partial kind
    bid=$(printf '%s' "$ujs" | jq -r '.query.userinfo.blockid // 0' 2>/dev/null)
    by=$(printf '%s' "$ujs" | jq -r '.query.userinfo.blockedby // "-"' 2>/dev/null)
    reason=$(printf '%s' "$ujs" | jq -r '.query.userinfo.blockreason // "-"' 2>/dev/null | tr -d '\n' | cut -c1-120)
    expiry=$(printf '%s' "$ujs" | jq -r '.query.userinfo.blockexpiry // "-"' 2>/dev/null)
    anon=$(printf '%s' "$ujs" | jq -r '.query.userinfo.anononly // false' 2>/dev/null)
    partial=$(printf '%s' "$ujs" | jq -r '.query.userinfo.blockpartial // false' 2>/dev/null)

    if [ "$bid" != "0" ] && [ -n "$bid" ]; then
      blocked=1
      kind="全站封禁"; [ "$anon" = "true" ] && kind="匿名-only 封禁"
      [ "$partial" = "true" ] && kind="部分封禁"
      lines+=("  $w  ⛔ 被封禁 ｜ $kind ｜ 期限 $expiry ｜ 执行者 $by ｜ 原因 $reason")
      results="${results}{\"wiki\":\"$w\",\"status\":\"blocked\",\"kind\":\"$kind\",\"expiry\":\"$expiry\",\"by\":\"$by\",\"reason\":\"$reason\"},"
    else
      [ "$BLOCK_ONLY" != 1 ] && lines+=("  $w  ✅ 未封禁")
      results="${results}{\"wiki\":\"$w\",\"status\":\"ok\"},"
    fi
  done

  # ---- 全局封禁 ----
  local gjs gcount=0 gdesc=""
  gjs=$(api_global "$ip" "$fam")
  if [ -z "$gjs" ]; then
    failed=1
    [ "$BLOCK_ONLY" != 1 ] && lines+=("  全局封禁(meta)  ⚠️  请求失败")
    results="${results}{\"scope\":\"global\",\"status\":\"error\"}"
  else
    gcount=$(printf '%s' "$gjs" | jq -r '(.query.globalblocks // []) | length' 2>/dev/null)
    if [ "${gcount:-0}" -gt 0 ]; then
      blocked=1
      gdesc=$(printf '%s' "$gjs" | jq -r '(.query.globalblocks // []) | map("\(.by // "-") · \(.expiry // "-") · \(((.reason // "-") | gsub("\n";" ") | .[0:60]))") | unique | .[0:3] | join(" ;; ")' 2>/dev/null)
      lines+=("  全局封禁(meta)  ⛔ 命中 $gcount 条 ｜ $gdesc")
      results="${results}{\"scope\":\"global\",\"status\":\"blocked\",\"count\":$gcount,\"detail\":\"$gdesc\"}"
    else
      [ "$BLOCK_ONLY" != 1 ] && lines+=("  全局封禁(meta)  ✅ 无")
      results="${results}{\"scope\":\"global\",\"status\":\"ok\"}"
    fi
  fi

  if [ "$JSON" = 1 ]; then
    printf '{"family":"v%s","ip":"%s","results":[%s]}\n' "$fam" "$ip" "${results%,}"
  elif [ "$BLOCK_ONLY" = 1 ]; then
    if [ "$blocked" = 1 ]; then
      print_header
      echo "IPv$fam $ip"
      for l in "${lines[@]}"; do echo "${l#  }"; done
    fi
  else
    echo "出口 IPv$fam: $ip"
    for l in "${lines[@]}"; do echo "$l"; done
  fi

  [ "$blocked" = 1 ] && return 1
  [ "$failed" = 1 ] && return 2
  return 0
}

HOST=$(hostname)
if [ "$JSON" != 1 ] && [ "$BLOCK_ONLY" != 1 ]; then
  echo "=== 维基封禁检测 · $HOST · $(date '+%Y-%m-%d %H:%M:%S') ==="
fi

rc=0
fams=()
if [ -n "$FAMILY" ]; then fams=("$FAMILY"); else fams=(4 6); fi
for f in "${fams[@]}"; do
  run_family "$f"; r=$?
  [ "$r" = 1 ] && rc=1
  [ "$r" = 2 ] && [ "$rc" != 1 ] && rc=2
done

if [ "$JSON" != 1 ] && [ "$BLOCK_ONLY" != 1 ]; then
  case "$rc" in
    0) echo "结论: ✅ 当前出口未被维基封禁" ;;
    1) echo "结论: ⛔ 当前出口被维基封禁（详见上方）" ;;
    *) echo "结论: ⚠️  无法判定（请求失败，可能线路不通或被中间设备拦截）" ;;
  esac
fi
exit "$rc"
