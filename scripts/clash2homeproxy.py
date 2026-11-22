#!/usr/bin/env python3
"""Clash 订阅 -> HomeProxy 分享链接订阅。

HomeProxy 不解析 Clash YAML，只接受分享链接（SS/VMess/VLESS/Trojan/Hysteria2
等）或这些链接的 base64 订阅。这个脚本从 Clash 订阅的 proxies 列表生成：

  homeproxy-links.txt   每行一个分享链接，可直接粘贴到 HomeProxy 的“导入分享链接”
  homeproxy-sub.b64     base64 后的链接列表，可上传到 N1 的 /www/ 作为订阅 URL

用法：
  python clash2homeproxy.py <订阅URL或YAML文件> [-o 输出目录]

依赖：
  pip install pyyaml
"""

from __future__ import annotations

import argparse
import base64
import gzip
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("缺少 PyYAML，请先执行: pip install pyyaml")


def quote(value) -> str:
    return urllib.parse.quote(str(value), safe="")


def b64_url(value: str) -> str:
    return base64.urlsafe_b64encode(value.encode()).decode().rstrip("=")


def b64_std(value: str) -> str:
    return base64.b64encode(value.encode()).decode()


def host_port(proxy: dict) -> tuple[str, str]:
    host = str(proxy.get("server") or proxy.get("address") or "").strip()
    port = str(proxy.get("port") or "").strip()
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return host, port


def ws_opts(proxy: dict) -> tuple[str, str]:
    opts = proxy.get("ws-opts") or {}
    headers = opts.get("headers") or {}
    host = headers.get("Host") or headers.get("host") or proxy.get("ws-host") or ""
    path = opts.get("path") or proxy.get("ws-path") or "/"
    return str(host), str(path)


def grpc_service(proxy: dict) -> str:
    opts = proxy.get("grpc-opts") or {}
    return str(opts.get("grpc-service-name") or opts.get("serviceName") or "")


def tls_on(proxy: dict, default: bool = False) -> bool:
    if proxy.get("tls") is True:
        return True
    if str(proxy.get("tls")).lower() in ("true", "1"):
        return True
    if str(proxy.get("security") or "").lower() in ("tls", "reality", "xtls"):
        return True
    return default


def sni(proxy: dict) -> str:
    return str(proxy.get("servername") or proxy.get("sni") or proxy.get("peer") or "")


def alpn(proxy: dict) -> str:
    value = proxy.get("alpn")
    if isinstance(value, list):
        return ",".join(str(item) for item in value)
    return str(value or "")


def insecure(proxy: dict) -> str:
    return "1" if proxy.get("skip-cert-verify") else "0"


def reality(proxy: dict) -> tuple[str, str]:
    opts = proxy.get("reality-opts") or {}
    return str(opts.get("public-key") or ""), str(opts.get("short-id") or "")


def build_ss(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    method = proxy.get("cipher")
    password = proxy.get("password")
    if not host or not port or not method or password is None:
        return None

    userinfo = b64_url(f"{method}:{password}")
    link = f"ss://{userinfo}@{host}:{port}"

    plugin = proxy.get("plugin")
    opts = proxy.get("plugin-opts") or {}
    plugin_str = ""
    if plugin == "obfs":
        plugin_str = (
            f"obfs-local;obfs={opts.get('mode', 'http')};"
            f"obfs-host={opts.get('host', '')}"
        )
    elif plugin == "v2ray-plugin":
        parts = ["v2ray-plugin", f"mode={opts.get('mode', 'websocket')}"]
        if opts.get("host"):
            parts.append(f"host={opts['host']}")
        if opts.get("path"):
            parts.append(f"path={opts['path']}")
        if opts.get("tls"):
            parts.append("tls")
        plugin_str = ";".join(parts)
    if plugin_str:
        link += "?plugin=" + quote(plugin_str)

    return link + "#" + quote(name)


def build_vmess(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    uuid = proxy.get("uuid")
    if not host or not port or not uuid:
        return None

    network = str(proxy.get("network") or "tcp")
    ws_host, ws_path = ws_opts(proxy)
    obj = {
        "v": "2",
        "ps": name,
        "add": host.strip("[]"),
        "port": port,
        "id": str(uuid),
        "aid": str(proxy.get("alterId", proxy.get("alterid", 0)) or 0),
        "scy": str(proxy.get("cipher") or "auto"),
        "net": network,
        "type": "none",
        "host": ws_host,
        "path": ws_path,
        "tls": "tls" if tls_on(proxy) else "",
        "sni": sni(proxy),
        "alpn": alpn(proxy),
    }
    if network == "grpc":
        obj["path"] = grpc_service(proxy)
        obj["type"] = "gun"
    elif network in ("h2", "http"):
        obj["type"] = "http"
        obj["host"] = ws_host
        obj["path"] = ws_path
    elif network == "httpupgrade":
        obj["host"] = ws_host
        obj["path"] = ws_path

    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return "vmess://" + b64_std(raw)


def build_vless(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    uuid = proxy.get("uuid")
    if not host or not port or not uuid:
        return None

    network = str(proxy.get("network") or "tcp")
    ws_host, ws_path = ws_opts(proxy)
    public_key, short_id = reality(proxy)
    is_reality = bool(proxy.get("reality-opts")) or str(proxy.get("security") or "") == "reality"
    security = "reality" if is_reality else ("tls" if tls_on(proxy) else "none")

    params = {
        "encryption": "none",
        "security": security,
        "type": network,
        "sni": sni(proxy),
        "alpn": alpn(proxy),
        "fp": str(proxy.get("client-fingerprint") or ""),
        "flow": str(proxy.get("flow") or ""),
        "pbk": public_key,
        "sid": short_id,
        "host": ws_host,
        "path": ws_path,
        "serviceName": grpc_service(proxy),
        "headerType": "none" if network in ("tcp", "ws", "grpc") else "http",
    }
    params = {key: value for key, value in params.items() if value}

    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return f"vless://{uuid}@{host}:{port}?{query}#{quote(name)}"


def build_trojan(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    password = proxy.get("password")
    if not host or not port or password is None:
        return None

    network = str(proxy.get("network") or "tcp")
    ws_host, ws_path = ws_opts(proxy)
    params = {
        "security": "tls" if tls_on(proxy, True) else "none",
        "sni": sni(proxy),
        "type": network,
        "host": ws_host,
        "path": ws_path,
        "serviceName": grpc_service(proxy),
        "alpn": alpn(proxy),
        "fp": str(proxy.get("client-fingerprint") or ""),
        "allowInsecure": insecure(proxy),
    }
    params = {key: value for key, value in params.items() if value}

    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return f"trojan://{quote(password)}@{host}:{port}?{query}#{quote(name)}"


def build_hysteria2(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    password = proxy.get("password")
    if password is None:
        password = proxy.get("auth")
    if not host or not port or password is None:
        return None

    params = {
        "sni": sni(proxy),
        "insecure": insecure(proxy),
        "obfs": str(proxy.get("obfs") or ""),
        "obfs-password": str(proxy.get("obfs-password") or ""),
    }
    params = {key: value for key, value in params.items() if value}

    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return f"hysteria2://{quote(password)}@{host}:{port}?{query}#{quote(name)}"


def build_tuic(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    uuid = proxy.get("uuid")
    password = proxy.get("password")
    if not host or not port or not uuid:
        return None

    params = {
        "sni": sni(proxy),
        "alpn": alpn(proxy),
        "congestion_control": str(
            proxy.get("congestion-controller")
            or proxy.get("congestion_control")
            or ""
        ),
        "udp_relay_mode": str(proxy.get("udp-relay-mode") or ""),
        "allow_insecure": insecure(proxy),
    }
    params = {key: value for key, value in params.items() if value}

    userinfo = f"{uuid}:{quote(password)}" if password else str(uuid)
    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return f"tuic://{userinfo}@{host}:{port}?{query}#{quote(name)}"


def build_anytls(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    password = proxy.get("password")
    if not host or not port or password is None:
        return None

    params = {
        "sni": sni(proxy),
        "insecure": insecure(proxy),
        "fp": str(proxy.get("client-fingerprint") or ""),
    }
    params = {key: value for key, value in params.items() if value}

    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return f"anytls://{quote(password)}@{host}:{port}?{query}#{quote(name)}"


def build_hysteria(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    auth = proxy.get("auth") or proxy.get("auth-str") or proxy.get("password") or ""
    if not host or not port:
        return None

    params = {
        "auth": str(auth),
        "peer": sni(proxy),
        "insecure": insecure(proxy),
        "upmbps": str(proxy.get("up") or ""),
        "downmbps": str(proxy.get("down") or ""),
        "protocol": str(proxy.get("protocol") or "udp"),
        "obfs": str(proxy.get("obfs") or ""),
    }
    params = {key: value for key, value in params.items() if value}

    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return f"hysteria://{host}:{port}?{query}#{quote(name)}"


def build_http(proxy: dict, name: str) -> str | None:
    host, port = host_port(proxy)
    if not host or not port:
        return None

    scheme = "socks5" if str(proxy.get("type")) in ("socks", "socks5") else "http"
    user = str(proxy.get("username") or proxy.get("user") or "")
    password = str(proxy.get("password") or "")
    auth = f"{quote(user)}:{quote(password)}@" if user else ""
    return f"{scheme}://{auth}{host}:{port}#{quote(name)}"


BUILDERS = {
    "ss": build_ss,
    "vmess": build_vmess,
    "vless": build_vless,
    "trojan": build_trojan,
    "hysteria": build_hysteria,
    "hysteria2": build_hysteria2,
    "hy2": build_hysteria2,
    "tuic": build_tuic,
    "anytls": build_anytls,
    "http": build_http,
    "https": build_http,
    "socks": build_http,
    "socks5": build_http,
}


def load_yaml(source: str) -> dict:
    if source.startswith(("http://", "https://")):
        request = urllib.request.Request(
            source,
            headers={
                "User-Agent": "clash-verge/v1.7.7",
                "Accept": "*/*",
                "Accept-Encoding": "identity",
            },
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
            if response.headers.get("Content-Encoding") == "gzip":
                data = gzip.decompress(data)
    else:
        data = Path(source).read_bytes()

    text = data.decode("utf-8-sig", "replace")
    try:
        return yaml.safe_load(text) or {}
    except yaml.YAMLError:
        # 少数订阅会先 base64 整个 YAML
        try:
            decoded = base64.b64decode(text.strip() + "===", validate=False)
            return yaml.safe_load(decoded.decode("utf-8")) or {}
        except Exception as exc:
            raise SystemExit(f"无法解析 YAML: {exc}") from exc


def main() -> None:
    parser = argparse.ArgumentParser(description="Clash 订阅转 HomeProxy 分享链接")
    parser.add_argument("source", help="Clash 订阅 URL 或本地 YAML 文件")
    parser.add_argument("-o", "--output", default=".", help="输出目录，默认当前目录")
    args = parser.parse_args()

    config = load_yaml(args.source)
    proxies = config.get("proxies") or []
    if not proxies:
        hint = "（发现 proxy-providers，请先在 Clash 里展开成 proxies）" if config.get("proxy-providers") else ""
        raise SystemExit(f"没有找到 proxies 列表{hint}")

    links: list[str] = []
    skipped: dict[str, int] = {}
    for proxy in proxies:
        node_type = str(proxy.get("type") or "").lower()
        builder = BUILDERS.get(node_type)
        if not builder:
            skipped[node_type or "?"] = skipped.get(node_type or "?", 0) + 1
            continue

        name = str(proxy.get("name") or f"{node_type}-{proxy.get('server')}:{proxy.get('port')}")
        try:
            link = builder(proxy, name)
        except Exception as exc:  # noqa: BLE001 - 单个节点失败不影响其它节点
            print(f"跳过 {name}: {exc}", file=sys.stderr)
            continue
        if link and link not in links:
            links.append(link)

    if not links:
        raise SystemExit("没有生成任何链接，请检查订阅格式")

    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    links_text = "\n".join(links) + "\n"
    (output / "homeproxy-links.txt").write_text(links_text, encoding="utf-8")
    (output / "homeproxy-sub.b64").write_text(b64_std(links_text), encoding="utf-8")

    print(f"生成 {len(links)} 个节点，输出到 {output.resolve()}")
    if skipped:
        detail = ", ".join(f"{key}={value}" for key, value in sorted(skipped.items()))
        print(f"跳过不支持的协议: {detail}")
    print()
    print("用法一：HomeProxy -> 节点 -> 导入分享链接，粘贴 homeproxy-links.txt 的内容")
    print("用法二：把 homeproxy-sub.b64 上传到 N1 的 /www/hp-sub.txt，")
    print("        在 HomeProxy -> 订阅里填 http://192.168.123.2:8080/hp-sub.txt")


if __name__ == "__main__":
    main()
