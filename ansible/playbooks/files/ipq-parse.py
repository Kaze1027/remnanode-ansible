#!/usr/bin/env python3
"""
解析 xykt/IPQuality 的 JSON 输出，生成【人类可读】的分行文本（供 Telegram 推送）。

用法：
    ipq-parse.py <结果文件> <节点名> [detail] [alerts-only]

    detail       : 解锁信息逐项展开（含解锁方式），仅作用于"全部输出"模式
    alerts-only  : 仅当该节点存在异常时才输出；节点内每行的 IP/组织/地区/类型都保留，
                   但解锁信息只保留【非原生 + 异常】项；完全正常的节点不输出

输出示例（alerts-only）：
    ▎us1.awso.cloud
    v4 · 23.147.120.204 · TAIPEI101 NETWORK LLC · 美国·North Kansas City · 原生IP
    v6 · 2600:1700:2bc1:409d:8::f80d · AT&T Enterprises, LLC · 美国·Warrenville · 原生IP · ⚠️ TikTok✖ AmazonPrime✘
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


def rows_of(media):
    media = media or {}
    out = []
    for key, label in SERVICES:
        item = media.get(key) or {}
        out.append((label, str(item.get("Status") or "?").strip(),
                    str(item.get("Region") or "").strip(),
                    str(item.get("Type") or "").strip()))
    return out


def media_full(rows, detail=False):
    """全部输出模式：正常项也显示。"""
    if detail:
        parts = []
        for label, status, region, kind in rows:
            sym = SYM.get(status, "?")
            extra = f"·{kind}" if kind and kind not in NATIVE else ("·原生" if status == "解锁" else "")
            parts.append(f"{label} {sym}{region}{extra}")
        return " ｜ ".join(parts)
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


def media_alerts(rows):
    """仅异常模式：只保留非原生 + 异常项；完全正常返回空串。"""
    bad, dns = [], []
    for label, status, region, kind in rows:
        if status != "解锁":
            bad.append(f"{label}{SYM.get(status, '?')}")
        elif kind and kind not in NATIVE:
            dns.append(f"{label}({kind})")
    if not bad and not dns:
        return ""
    text = "⚠️ " + " ".join(bad) if bad else "⚠️"
    if dns:
        text += (" ｜ " if bad else " ") + "非原生解锁: " + " ".join(dns)
    return text.strip()


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ipq-raw.json"
    host = sys.argv[2] if len(sys.argv) > 2 else "unknown"
    detail = False
    alerts_only = False
    wiki_file = None
    rest = list(sys.argv[3:])
    i = 0
    while i < len(rest):
        arg = str(rest[i]).strip()
        low = arg.lower()
        if low == "--wiki" and i + 1 < len(rest):
            wiki_file = rest[i + 1]
            i += 2
            continue
        if low.startswith("--wiki="):
            wiki_file = arg.split("=", 1)[1]
            i += 1
            continue
        if low in ("detail", "1", "true"):
            detail = True
        elif low in ("alerts-only", "alerts", "only-alerts"):
            alerts_only = True
        i += 1

    wiki_line = ""
    if wiki_file:
        try:
            with open(wiki_file, encoding="utf-8", errors="replace") as fh:
                wiki_line = (fh.readline() or "").strip()
        except OSError:
            wiki_line = ""

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

    entries = []
    for obj in objs:
        head = obj.get("Head") or {}
        info = obj.get("Info") or {}
        ip = clean(head.get("IP"))
        family = "v6" if ":" in ip else "v4"
        org = clean(info.get("Organization"))
        region = region_text(info)
        city = clean((info.get("City") or {}).get("Name"))
        kind = clean(info.get("Type"))
        place = f"{region}·{city}" if city != "-" else region
        base = f"{family} · {ip} · {org} · {place} · {kind}"
        rows = rows_of(obj.get("Media"))
        short = media_alerts(rows)
        entries.append({
            "base": base,
            "full": media_full(rows, detail),
            "short": short,
            "abnormal": bool(short) or kind != "原生IP",
        })

    wiki_blocked = "⛔" in wiki_line

    if alerts_only:
        if not any(e["abnormal"] for e in entries) and not wiki_blocked:
            return 0
        print(f"▎{host}")
        for e in entries:
            # 保留每行的 IP/组织/地区/类型；解锁信息只留非原生与异常
            print(f"{e['base']} · {e['short']}" if e["short"] else e["base"])
        if wiki_line:
            print(wiki_line)
        return 0

    print(f"▎{host}")
    for e in entries:
        print(f"{e['base']} · {e['full']}")
    if wiki_line:
        print(wiki_line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
