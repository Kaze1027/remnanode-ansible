#!/bin/bash
# Aether 时钟看门狗（极低开销：正常时只调用一次 chronyc tracking 即退出）
# 背景：Shadowsocks-2022 校验握手时间戳，容差约 ±30 秒；
#       VM 被宿主机挂起/迁移会造成小时级跳变，必须立即步进，否则该节点整体不可用。
set -u
TAG=clock-watchdog
LIMIT_MS=30000
log() { logger -t "$TAG" "$*" 2>/dev/null || true; }

off_ms() {  # 从 chronyc tracking 取 "System time" 转成毫秒绝对值；取不到返回 999999999
  local s
  s=$(chronyc tracking 2>/dev/null | awk -F': *' '/^System time/{print $2}' | awk '{print $1}')
  case "${s:-}" in
    ''|*[!0-9eE+.-]*) echo 999999999 ;;
    *) awk -v o="$s" 'BEGIN{d=o*1000; if(d<0)d=-d; printf "%d", d}' ;;
  esac
}
synced() { timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown; }

sync=$(synced); ms=$(off_ms)
# 正常：已同步且偏差在阈值内 -> 直接退出（零动作）
if [ "$sync" = "yes" ] && [ "$ms" -le "$LIMIT_MS" ]; then
  exit 0
fi

log "abnormal: sync=$sync offset=${ms}ms -> force step"
systemctl restart chrony >/dev/null 2>&1 || true
sleep 3
chronyc makestep >/dev/null 2>&1 || true
sleep 3

sync2=$(synced); ms2=$(off_ms)
if [ "$sync2" = "yes" ] && [ "$ms2" -le "$LIMIT_MS" ]; then
  log "recovered by chrony (offset=${ms2}ms)"
  exit 0
fi

# 兜底：chrony 无可用源时，用 HTTP Date 头强制对时（临时停 chrony 避免互相拉扯）
for url in https://www.cloudflare.com https://www.baidu.com https://www.qq.com; do
  d=$(curl -sI -m 8 "$url" 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
  [ -n "${d:-}" ] || continue
  refs=$(date -u -d "$d" +%s 2>/dev/null || echo "")
  [ -n "$refs" ] || continue
  nows=$(date -u +%s); diff=$(( nows - refs )); [ $diff -lt 0 ] && abs=$(( -diff )) || abs=$diff
  if [ "$abs" -gt 5 ]; then
    systemctl stop chrony >/dev/null 2>&1 || true
    date -u -s "$d" >/dev/null 2>&1 && log "forced via HTTP Date ($url), was off ${abs}s"
    hwclock -w >/dev/null 2>&1 || true
    systemctl start chrony >/dev/null 2>&1 || true
    sleep 2
    chronyc makestep >/dev/null 2>&1 || true
  fi
  break
done
exit 0
