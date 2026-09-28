#!/usr/bin/env python3
"""
ddns-hub —— 接收节点签名的 IP 上报，更新阿里云 DNS 的 A / AAAA 记录。

安全模型：
  - 每台节点一份独立 HMAC-SHA256 密钥（/etc/ddns-hub/secrets.json）
  - 白名单：节点只能更新映射给自己的记录（/etc/ddns-hub/records.json）
  - 时间戳偏移 > DDNS_TS_SKEW 秒拒绝；nonce 防重放
  - 无变化不调用阿里云 API

环境变量：
  ALICLOUD_ACCESS_KEY_ID / ALICLOUD_ACCESS_KEY_SECRET   （复用 Caddy 的 .env）
  DDNS_LISTEN       默认 172.18.0.1:8787（docker 网桥网关，仅容器可达）
  DDNS_RECORDS_FILE 默认 /etc/ddns-hub/records.json
  DDNS_SECRETS_FILE 默认 /etc/ddns-hub/secrets.json
  DDNS_TS_SKEW      默认 300
"""
import base64, hashlib, hmac, ipaddress, json, os, time, urllib.parse, urllib.request, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CK = os.environ.get("ALICLOUD_ACCESS_KEY_ID", "")
CS = os.environ.get("ALICLOUD_ACCESS_KEY_SECRET", "")
LISTEN = os.environ.get("DDNS_LISTEN", "172.18.0.1:8787")
RECORDS_FILE = os.environ.get("DDNS_RECORDS_FILE", "/etc/ddns-hub/records.json")
SECRETS_FILE = os.environ.get("DDNS_SECRETS_FILE", "/etc/ddns-hub/secrets.json")
TS_SKEW = int(os.environ.get("DDNS_TS_SKEW", "300"))
ENDPOINT = "https://alidns.aliyuncs.com/"
SEEN_NONCES = {}


def log(msg):
    print(f"[ddns-hub] {msg}", flush=True)


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as exc:  # noqa: BLE001
        log(f"WARN cannot read {path}: {exc}")
        return default


def pct(v):
    return urllib.parse.quote(str(v), safe="~")


def alidns(action, params):
    if not CK or not CS:
        raise RuntimeError("ALICLOUD_ACCESS_KEY_ID/SECRET 未配置")
    p = {
        "Format": "JSON",
        "Version": "2015-01-09",
        "AccessKeyId": CK,
        "SignatureMethod": "HMAC-SHA1",
        "SignatureVersion": "1.0",
        "SignatureNonce": uuid.uuid4().hex,
        "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "Action": action,
    }
    p.update({k: v for k, v in params.items() if v is not None})
    canonical = "&".join(f"{pct(k)}={pct(p[k])}" for k in sorted(p))
    to_sign = "GET&%2F&" + pct(canonical)
    sig = base64.b64encode(
        hmac.new((CS + "&").encode(), to_sign.encode(), hashlib.sha1).digest()
    ).decode()
    url = f"{ENDPOINT}?{canonical}&Signature={pct(sig)}"
    req = urllib.request.Request(url, headers={"User-Agent": "ddns-hub/1.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def find_record(zone, rr, rtype):
    data = alidns("DescribeDomainRecords", {"DomainName": zone, "RRKeyWord": rr,
                                            "Type": rtype, "PageSize": 100})
    for rec in data.get("DomainRecords", {}).get("Record", []):
        if rec.get("RR") == rr and rec.get("Type") == rtype:
            return rec
    return None


def apply_record(zone, rr, rtype, value):
    rec = find_record(zone, rr, rtype)
    if rec and rec.get("Value") == value:
        return False, f"{rr}.{zone} {rtype} 已是 {value}"
    if rec:
        alidns("UpdateDomainRecord", {"RecordId": rec["RecordId"], "RR": rr,
                                      "Type": rtype, "Value": value, "TTL": rec.get("TTL", 600)})
        return True, f"{rr}.{zone} {rtype}: {rec.get('Value')} -> {value}"
    alidns("AddDomainRecord", {"DomainName": zone, "RR": rr, "Type": rtype,
                               "Value": value, "TTL": 600})
    return True, f"{rr}.{zone} {rtype}: 新建 {value}"


def valid_ip(value, version):
    if not value:
        return False
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    return ip.version == version


def sign(secret, host, ip4, ip6, ts):
    msg = f"{host}\n{ip4}\n{ip6}\n{ts}".encode()
    return hmac.new(secret.encode(), msg, hashlib.sha256).hexdigest()


class Handler(BaseHTTPRequestHandler):
    server_version = "ddns-hub/1.0"

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # 交给 journald 即可
        log(f"{self.address_string()} {fmt % args}")

    def do_GET(self):  # noqa: N802
        if self.path.rstrip("/") in ("/healthz", "/ddns/healthz"):
            records = load_json(RECORDS_FILE, {})
            return self._send(200, {"ok": True, "records": len(records),
                                    "aliyun_key": bool(CK and CS)})
        return self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):  # noqa: N802
        if self.path.rstrip("/") not in ("/update", "/ddns/update"):
            return self._send(404, {"ok": False, "error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 8192:
                return self._send(400, {"ok": False, "error": "bad body"})
            req = json.loads(self.rfile.read(length).decode())
        except Exception as exc:  # noqa: BLE001
            return self._send(400, {"ok": False, "error": f"json: {exc}"})

        host = str(req.get("host", "")).strip().lower()
        ip4 = str(req.get("ip4", "") or "").strip()
        ip6 = str(req.get("ip6", "") or "").strip()
        ts = req.get("ts")
        sig = str(req.get("sig", "")).strip().lower()

        records = load_json(RECORDS_FILE, {})
        secrets = load_json(SECRETS_FILE, {})
        entry = records.get(host)
        secret = secrets.get(host)
        if not entry or not secret:
            return self._send(403, {"ok": False, "error": f"{host} 不在白名单"})
        if not isinstance(ts, int):
            return self._send(400, {"ok": False, "error": "ts 缺失"})
        if abs(time.time() - ts) > TS_SKEW:
            return self._send(400, {"ok": False, "error": "时间戳偏移过大"})
        if not hmac.compare_digest(sign(secret, host, ip4, ip6, ts), sig):
            return self._send(403, {"ok": False, "error": "签名校验失败"})
        nonce = f"{host}:{ts}:{sig}"
        now = time.time()
        for k in [k for k, v in SEEN_NONCES.items() if now - v > 600]:
            SEEN_NONCES.pop(k, None)
        if nonce in SEEN_NONCES:
            return self._send(409, {"ok": False, "error": "重复上报"})
        SEEN_NONCES[nonce] = now

        want4 = ip4 if valid_ip(ip4, 4) else None
        want6 = ip6 if valid_ip(ip6, 6) else None
        if not want4 and not want6:
            return self._send(400, {"ok": False, "error": "没有可用的 IP"})

        zone = entry["zone"]
        rr = entry["rr"]
        results = []
        try:
            if want4:
                changed, detail = apply_record(zone, rr, "A", want4)
                results.append(detail)
            if want6:
                changed, detail = apply_record(zone, rr, "AAAA", want6)
                results.append(detail)
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR {host}: {exc}")
            return self._send(502, {"ok": False, "error": str(exc)})
        log(f"{host} ip4={want4} ip6={want6} -> {'; '.join(results)}")
        return self._send(200, {"ok": True, "host": host, "results": results})


def main():
    host, _, port = LISTEN.rpartition(":")
    log(f"listening on {host or '0.0.0.0'}:{port or '8787'} (aliyun_key={bool(CK and CS)})")
    ThreadingHTTPServer((host or "0.0.0.0", int(port or 8787)), Handler).serve_forever()


if __name__ == "__main__":
    main()
