#!/usr/bin/env python3
"""
解析 xykt/IPQuality 的 JSON 输出（可能带赞助商 banner，可能是 IPv4+IPv6 多段对象），
输出紧凑单行（每段一行）：
    <host> [v4|v6] <IP> | <Organization>\\<Region.Name>-<City.Name>\\<Type> | <Media 摘要>
"""
import json
import sys

SHORT = [("TikTok", "TikTok"), ("DisneyPlus", "Disney"), ("Netflix", "Netflix"),
         ("Youtube", "YouTube"), ("AmazonPrimeVideo", "Prime"), ("Reddit", "Reddit"),
         ("ChatGPT", "ChatGPT")]
SYM = {"解锁": "✔", "屏蔽": "✘", "失败": "✖"}


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


def media_str(media):
    media = media or {}
    parts = []
    for key, short in SHORT:
        m = media.get(key) or {}
        status = str(m.get("Status") or "?")
        region = str(m.get("Region") or "")
        sym = SYM.get(status, "?")
        if status == "解锁" and region:
            parts.append(f"{short}{sym}{region}")
        else:
            parts.append(f"{short}{sym}")
    return " ".join(parts)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ipq-raw.json"
    host = sys.argv[2] if len(sys.argv) > 2 else "unknown"
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    objs = load_objects(raw)
    if not objs:
        print(f"{host} | PARSE-FAIL | 无有效 JSON（脚本可能失败）")
        return 1
    for obj in objs:
        head = obj.get("Head") or {}
        info = obj.get("Info") or {}
        ip = str(head.get("IP") or "?")
        fam = "v6" if ":" in ip else "v4"
        org = str(info.get("Organization") or "?")
        region = str((info.get("Region") or {}).get("Name") or "?")
        city = str((info.get("City") or {}).get("Name") or "?")
        typ = str(info.get("Type") or "?")
        print(f"{host} [{fam}] {ip} | {org}\\{region}-{city}\\{typ} | {media_str(obj.get('Media'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
