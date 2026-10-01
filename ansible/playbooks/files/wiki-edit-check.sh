#!/bin/bash
# ============================================================================
# wiki-edit-check.sh —— 检测【当前出口 IP】能否编辑维基百科
#
#   逻辑借鉴：https://github.com/HsukqiLee/MediaUnlockTest  (pkg/providers/Wikipedia.go)
#     · 请求 URL：https://zh.wikipedia.org/w/index.php?title=Wikipedia%3A沙盒&action=edit
#     · 浏览器 UA + 常规浏览器请求头（未登录/匿名身份）
#     · 判定：
#         - 请求失败                    → 网络错误（无法判定）
#         - 页面含 "Banned"             → ⛔ 不可编辑
#         - HTTP 429                    → ⛔ 被封禁/限流
#         - HTTP 200 且返回编辑表单      → ✅ 可编辑
#         - HTTP 200 但无编辑表单        → ⛔ 不可编辑（参照实现只判 200，会把"查看源代码"误判为可编辑，此处补正）
#         - 其它状态码                   → 意外状态
#   被判定不可编辑时，会额外查维基 API（blockinfo / globalblocks）说明原因与期限。
#
#   依赖：curl、jq（仅用于"原因说明"，缺失也能给出结论）
#
# 用法：
#   ./wiki-edit-check.sh                     # 当前出口 v4 + v6 都测
#   ./wiki-edit-check.sh -4 | -6             # 只测某一族
#   ./wiki-edit-check.sh -6 --native         # 用【原生 IPv6】出口测（自动排除 Aether 租约段）
#   ./wiki-edit-check.sh -i 2602:faa8::a     # 指定源地址
#   ./wiki-edit-check.sh --json              # JSON（每族一行）
#   ./wiki-edit-check.sh --block --tag "node-03 (us3.awso.cloud)"   # 只输出"不可编辑"项
#   ./wiki-edit-check.sh -H "zh.wikipedia.org|Wikipedia:沙盒"       # 换目标（host|标题）
#
# 退出码：0=可编辑  1=不可编辑  2=无法判定
# ============================================================================
set -uo pipefail

META="meta.wikimedia.org"
UA="${WIKI_UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36}"
TIMEOUT="${WIKI_TIMEOUT:-20}"
TARGETS_DEFAULT="zh.wikipedia.org|Wikipedia:沙盒"

HDRS=(
  -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9'
  -H 'accept-language: zh-CN,zh;q=0.9,en;q=0.8'
  -H 'sec-ch-ua: "Not A(Brand";v="99", "Google Chrome";v="146", "Chromium";v="146"'
  -H 'sec-ch-ua-mobile: ?0'
  -H 'sec-ch-ua-platform: "Windows"'
  -H 'sec-fetch-site: cross-site'
  -H 'sec-fetch-mode: navigate'
  -H 'sec-fetch-dest: document'
  -H 'sec-fetch-user: ?1'
  -H 'upgrade-insecure-requests: 1'
  -H 'cache-control: no-cache'
  -H 'pragma: no-cache'
  -H 'dnt: 1'
)

FAMILY=""
BIND=""
NATIVE=0
JSON=0
BLOCK_ONLY=0
SUMMARY=0
TAG=""
TARGETS="$TARGETS_DEFAULT"
SUM=()

while [ $# -gt 0 ]; do
  case "$1" in
    -4) FAMILY=4 ;;
    -6) FAMILY=6 ;;
    -i) shift; BIND="${1:-}" ;;
    --native) NATIVE=1; FAMILY=6 ;;
    -H|--hosts|--targets) shift; TARGETS="${1:-}" ;;
    --json) JSON=1 ;;
    --block) BLOCK_ONLY=1 ;;
    --summary) SUMMARY=1 ;;
    --tag) shift; TAG="${1:-}" ;;
    -t|--timeout) shift; TIMEOUT="${1:-20}" ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------- 原生 IPv6 自动识别（排除 Aether 租约段 2600:1700:2bc1:409d::/48 与 /128） ----------
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

urlenc() { jq -rn --arg v "$1" '$v|@uri' 2>/dev/null || printf '%s' "$1"; }

fetch() {  # $1=url $2=fam $3=outfile → 输出 http code
  local extra=()
  [ -n "$BIND" ] && extra=(--interface "$BIND")
  curl $(fam_args "$2") "${extra[@]}" --noproxy '*' -sS -A "$UA" "${HDRS[@]}" \
    -o "$3" -w '%{http_code}' --max-time "$TIMEOUT" "$1" 2>/dev/null
}

# 维基侧封禁说明（仅用于解释原因；jq 缺失时静默跳过）
block_reason() {  # $1=host $2=ip $3=fam
  command -v jq >/dev/null 2>&1 || return 0
  local extra=(); [ -n "$BIND" ] && extra=(--interface "$BIND")
  local js kind expiry reason
  js=$(curl $(fam_args "$3") "${extra[@]}" --noproxy '*' -sS -A "$UA" --max-time 12 \
        "https://$1/w/api.php?action=query&meta=userinfo&uiprop=blockinfo&format=json&formatversion=2" 2>/dev/null)
  kind=$(printf '%s' "$js" | jq -r 'if (.query.userinfo.blockid // 0) != 0 then (if .query.userinfo.anononly then "匿名-only 封禁" else "全站封禁" end) else "" end' 2>/dev/null)
  expiry=$(printf '%s' "$js" | jq -r '.query.userinfo.blockexpiry // ""' 2>/dev/null)
  reason=$(printf '%s' "$js" | jq -r '.query.userinfo.blockreason // ""' 2>/dev/null | tr -d '\n' | cut -c1-80)
  if [ -n "$kind" ]; then
    printf '维基侧: %s%s%s' "$kind" "${expiry:+ · 期限 $expiry}" "${reason:+ · 原因 $reason}"
    return 0
  fi
  local gjs
  gjs=$(curl $(fam_args "$3") "${extra[@]}" --noproxy '*' -sS -A "$UA" --max-time 12 \
        --get --data-urlencode "bgip=$2" \
        "https://$META/w/api.php?action=query&list=globalblocks&format=json&formatversion=2&bglimit=5" 2>/dev/null)
  local gcount
  gcount=$(printf '%s' "$gjs" | jq -r '(.query.globalblocks // []) | length' 2>/dev/null)
  if [ "${gcount:-0}" -gt 0 ]; then
    printf '维基侧: 全局封禁 %s 条' "$gcount"
  fi
}

HDR_PRINTED=0
print_header() { [ "$HDR_PRINTED" = 1 ] && return; [ -n "$TAG" ] && echo "▎$TAG"; HDR_PRINTED=1; }

# ---------- 判定单次请求 ----------
judge() {  # $1=http_code $2=body_file → 输出 "editable|blocked|unexpected" 与说明
  local code="$1" body="$2" detail=""
  if grep -qi 'banned' "$body" 2>/dev/null; then
    echo "blocked|页面含 Banned 标记"; return
  fi
  if [ "$code" = "429" ]; then
    echo "blocked|HTTP 429（限流/封禁）"; return
  fi
  if [ "$code" = "200" ]; then
    if grep -q 'permissions-errors' "$body" 2>/dev/null; then
      echo "blocked|权限受限（permissions-errors，实际为“查看源代码”）"; return
    fi
    if grep -q 'wpSave' "$body" 2>/dev/null; then
      echo "editable|编辑表单正常"; return
    fi
    echo "blocked|未返回编辑表单"
    return
  fi
  echo "unexpected|HTTP $code"
}

# ---------- 单族检测 ----------
run_family() {  # $1=fam
  local fam="$1"
  local out="/tmp/wiki-edit-$fam.html" results="" lines=() any_blocked=0 any_fail=0 ip_known=""
  local code title verdict detail

  for t in $TARGETS; do
    local host="${t%%|*}" titlepart="Wikipedia:沙盒"
    case "$t" in *"|"*) titlepart="${t#*|}" ;; esac
    local url="https://$host/w/index.php?title=$(urlenc "${titlepart// /_}" | sed 's/%3A/:/g')&action=edit"
    code=$(fetch "$url" "$fam" "$out")
    if [ -z "$code" ] || [ "$code" = "000" ]; then
      any_fail=1
      [ "$BLOCK_ONLY" != 1 ] && lines+=("  $host  ⚠️  请求失败（网络/线路问题）")
      results="${results}{\"host\":\"$host\",\"status\":\"network_error\"},"
      continue
    fi
    title=$(grep -o '<title>[^<]*' "$out" 2>/dev/null | head -1 | sed 's/<title>//')
    IFS='|' read -r verdict detail <<< "$(judge "$code" "$out")"

    local famlabel="v$fam"
    [ "$NATIVE" = 1 ] && famlabel="v$fam(原生)"

    case "$verdict" in
      editable)
        [ "$BLOCK_ONLY" != 1 ] && [ "$SUMMARY" != 1 ] && lines+=("  $host  ✅ 可编辑（$detail ｜ $title）")
        results="${results}{\"host\":\"$host\",\"status\":\"editable\",\"http\":$code,\"title\":\"${title}\"},"
        SUM+=("$famlabel ✅可编辑")
        ;;
      blocked)
        any_blocked=1
        local why="" shortd="" shortr=""
        why=$(block_reason "$host" "" "$fam")
        case "$detail" in
          *Banned*) shortd="Banned" ;;
          *429*) shortd="HTTP429" ;;
          *permissions-errors*) shortd="权限受限" ;;
          *"未返回编辑表单"*) shortd="无编辑表单" ;;
          *) shortd="$detail" ;;
        esac
        if [ -n "$why" ]; then
          local kind d
          kind=$(printf '%s' "$why" | sed -n 's/.*维基侧: \([^·]*\) ·.*/\1/p' | tr -d ' ')
          d=$(printf '%s' "$why" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | head -1)
          shortr="${kind}${d:+·$d}"
          [ -z "$shortr" ] && shortr="$why"
        fi
        [ "$BLOCK_ONLY" != 1 ] && [ "$SUMMARY" != 1 ] && lines+=("  $host  ⛔ 不可编辑 ｜ $detail${why:+ ｜ $why}")
        results="${results}{\"host\":\"$host\",\"status\":\"blocked\",\"http\":$code,\"detail\":\"$detail\",\"title\":\"${title}\"},"
        SUM+=("$famlabel ⛔不可编辑(${shortd}${shortr:+/$shortr})")
        ;;
      *)
        any_fail=1
        [ "$BLOCK_ONLY" != 1 ] && [ "$SUMMARY" != 1 ] && lines+=("  $host  ⚠️  意外状态（$detail）")
        results="${results}{\"host\":\"$host\",\"status\":\"unexpected\",\"http\":$code},"
        SUM+=("$famlabel ⚠️$detail")
        ;;
    esac
  done

  # 取出口 IP（用于展示/JSON）
  if command -v jq >/dev/null 2>&1; then
    local extra=(); [ -n "$BIND" ] && extra=(--interface "$BIND")
    ip_known=$(curl $(fam_args "$fam") "${extra[@]}" --noproxy '*' -sS -A "$UA" --max-time 12 \
      "https://$META/w/api.php?action=query&meta=userinfo&format=json&formatversion=2" 2>/dev/null \
      | jq -r '.query.userinfo.name // empty' 2>/dev/null)
  fi

  if [ "$JSON" = 1 ]; then
    printf '{"family":"v%s","ip":"%s","results":[%s]}\n' "$fam" "${ip_known:-}" "${results%,}"
  elif [ "$SUMMARY" = 1 ]; then
    :   # 摘要模式：统一在最后输出
  elif [ "$BLOCK_ONLY" = 1 ]; then
    if [ "$any_blocked" = 1 ]; then
      print_header
      echo "IPv$fam${ip_known:+ $ip_known}"
      for l in "${lines[@]}"; do echo "${l#  }"; done
    fi
  else
    echo "出口 IPv$fam${ip_known:+: $ip_known}"
    for l in "${lines[@]}"; do echo "$l"; done
  fi

  [ "$any_blocked" = 1 ] && return 1
  [ "$any_fail" = 1 ] && return 2
  return 0
}

if [ "$JSON" != 1 ] && [ "$BLOCK_ONLY" != 1 ] && [ "$SUMMARY" != 1 ]; then
  echo "=== 维基百科可编辑性检测 · $(hostname) · $(date '+%Y-%m-%d %H:%M:%S') ==="
fi

rc=0
fams=()
if [ -n "$FAMILY" ]; then fams=("$FAMILY"); else fams=(4 6); fi
for f in "${fams[@]}"; do
  run_family "$f"; r=$?
  [ "$r" = 1 ] && rc=1
  [ "$r" = 2 ] && [ "$rc" != 1 ] && rc=2
done

if [ "$SUMMARY" = 1 ]; then
  sum_out=""
  for s in "${SUM[@]:-}"; do sum_out="${sum_out}${sum_out:+ ｜ }${s}"; done
  printf 'wiki 可编辑性: %s\n' "${sum_out:-n/a}"
  exit "$rc"
fi

if [ "$JSON" != 1 ] && [ "$BLOCK_ONLY" != 1 ]; then
  case "$rc" in
    0) echo "结论: ✅ 当前出口可以编辑维基百科" ;;
    1) echo "结论: ⛔ 当前出口无法编辑维基百科（详见上方）" ;;
    *) echo "结论: ⚠️  无法判定" ;;
  esac
fi
exit "$rc"
