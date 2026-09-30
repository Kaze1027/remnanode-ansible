#!/usr/bin/env python3
"""
解析 xykt/IPQuality 的 JSON 输出，生成【人类可读】的分行文本（供 Telegram 推送）。

用法：
    ipq-parse.py <结果文件> <节点名> [detail] [alerts-only]

    detail       : 媒体逐项展开（含解锁方式），默认只列异常项
    alerts-only  : 只输出"异常/非原生"的行；该节点完全正常则不输出任何内容

输出示例（alerts-only）：
    ▎us34.awso.cloud
    v4 · 162.251.204.47 · Oneman Network Limited · 美国 · 原生IP · ⚠️ AmazonPrime✘ ｜ 其余6项解锁（全部原生）
"""
import json
import sys

SERVICES = [
    ("TikTok", "TikTok"),
    ("DisneyPlus", "Disney+"),
    ("Netflix", "Netflix"),
    ("Youtube", "YouTube"),
    ("AmazonPrimeVideo", "AmazonPrime"),
    ("Reddit", "Reddit"),
    ("ChatGPT", "ChatGPT"),
]
SYM = {"解锁": "✔", "屏蔽": "✘", "失败": "✖"}
PLACEHOLDER = {"", "null", "none", "n/a", "na"}
NATIVE = {"原生", "native"}

REGION_ZH = {
    "US": "美国", "CA": "加拿大", "MX": "墨西哥", "BR": "巴西", "AR": "阿根廷",
    "CL": "智利", "CO": "哥伦比亚", "PE": "秘鲁",
    "GB": "英国", "IE": "爱尔兰", "FR": "法国", "DE": "德国", "NL": "荷兰",
    "BE": "比利时", "LU": "卢森堡", "CH": "瑞士", "AT": "奥地利", "IT": "意大利",
    "ES": "西班牙", "PT": "葡萄牙", "SE": "瑞典", "NO": "挪威", "DK": "丹麦",
    "FI": "芬兰", "IS": "冰岛", "PL": "波兰", "CZ": "捷克", "SK": "斯洛伐克",
    "HU": "匈牙利", "RO": "罗马尼亚", "BG": "保加利亚", "GR": "希腊", "UA": "乌克兰",
    "RU": "俄罗斯", "LT": "立陶宛", "LV": "拉脱维亚", "EE": "爱沙尼亚",
    "TR": "土耳其", "IL": "以色列", "AE": "阿联酋", "SA": "沙特阿拉伯", "EG": "埃及",
    "ZA": "南非", "NG": "尼日利亚", "KE": "肯尼亚",
    "CN": "中国", "HK": "中国香港", "TW": "中国台湾", "MO": "中国澳门",
    "JP": "日本", "KR": "韩国", "SG": "新加坡", "MY": "马来西亚", "TH": "泰国",
    "VN": "越南", "PH": "菲律宾", "ID": "印度尼西亚", "IN": "印度", "PK": "巴基斯坦",
    "BD": "孟加拉国", "LK": "斯里兰卡", "NP": "尼泊尔",
    "AU": "澳大利亚", "NZ": "新西兰",
}


def load_objects(raw):
    dec = json.JSONDecoder()
    objs, idx = [], 0
    while idx < len(raw):
        nxt = raw.find("{", idx)
        if nxt < 0:
            break
        try:
            obj, end = dec.raw_decode(raw, nxt)
        except ValueError:
            idx = nxt + 1
            continue
        objs.append(obj)
        idx = end
    return objs


def clean(value):
    text = str(value if value is not None else "").strip()
    return "-" if text.lower() in PLACEHOLDER else text


def region_text(info):
    region = info.get("Region") or {}
    code = clean(region.get("Code"))
    name = clean(region.get("Name"))
    if code != "-" and code in REGION_ZH:
        return REGION_ZH[code]
    return name


def media_text(media, detail=False):
    media = media or {}
    rows = []
    for key, label in SERVICES:
        item = media.get(key) or {}
        rows.append((label, str(item.get("Status") or "?").strip(),
                     str(item.get("Region") or "").strip(),
                     str(item.get("Type") or "").strip()))

    if detail:
        out = []
        for label, status, region, kind in rows:
            sym = SYM.get(status, "?")
            extra = f"·{kind}" if kind and kind not in NATIVE else ("·原生" if status == "解锁" else "")
            out.append(f"{label} {sym}{region}{extra}")
        return " ｜ ".join(out)

    unlocked = [r for r in rows if r[1] == "解锁"]
    bad = [f"{label}{SYM.get(status, '?')}" for label, status, _, _ in rows if status != "解锁"]
    nonnative = [label for label, status, _, kind in rows if status == "解锁" and kind and kind not in NATIVE]

    if not bad:
        head = f"✅ 全解锁（{len(unlocked)}/{len(rows)}"
        head += f" · 其中 {'、'.join(nonnative)}=DNS）" if nonnative else " · 全部原生）"
        return head
    tail = f" ｜ 其余{len(unlocked)}项解锁"
    if unlocked:
        tail += f"（其中 {'、'.join(nonnative)}=DNS）" if nonnative else "（全部原生）"
    return "⚠️ " + " ".join(bad) + tail


def build_lines(obj, detail):
    head = obj.get("Head") or {}
    info = obj.get("Info") or {}
    ip = clean(head.get("IP"))
    family = "v6" if ":" in ip else "v4"
    org = clean(info.get("Organization"))
    region = region_text(info)
    city = clean((info.get("City") or {}).get("Name"))
    kind = clean(info.get("Type"))
    place = f"{region}·{city}" if city != "-" else region
    media = media_text(obj.get("Media"), detail)
    line = f"{family} · {ip} · {org} · {place} · {kind} · {media}"
    abnormal = ("✘" in media or "✖" in media or "=DNS" in media
                or kind != "原生IP" or "采集失败" in line)
    return line, abnormal


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ipq-raw.json"
    host = sys.argv[2] if len(sys.argv) > 2 else "unknown"
    flags = {str(a).strip().lower() for a in sys.argv[3:]}
    detail = bool({"detail", "1", "true"} & flags)
    alerts_only = bool({"alerts-only", "alerts", "only-alerts"} & flags)

    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        print(f"▎{host}")
        print(f"⚠️ 采集失败：无法读取结果文件（{exc}）")
        return 1

    objs = load_objects(raw)
    if not objs:
        print(f"▎{host}")
        print("⚠️ 采集失败：未取到有效 JSON（可查看 /var/lib/ipquality/latest.err）")
        return 1

    lines, bad_lines = [], []
    for obj in objs:
        line, abnormal = build_lines(obj, detail)
        lines.append(line)
        if abnormal:
            bad_lines.append(line)

    if alerts_only:
        if not bad_lines:
            return 0
        print(f"▎{host}")
        for line in bad_lines:
            print(line)
        return 0

    print(f"▎{host}")
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
