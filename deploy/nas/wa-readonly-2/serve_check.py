#!/usr/bin/env python3
"""Fail-closed parsers for the NAS preflight. Standard library only."""

import json
import sys

SUBNET = "172.30.240.0/29"
HOST_443 = "nas-2021.tailba1801.ts.net:443"
HOST_44443 = "nas-2021.tailba1801.ts.net:44443"
PROXY_443 = "http://127.0.0.1:8088"
PROXY_44443 = "http://127.0.0.1:12789/mcp"
BLOCKED_PORTS = {12789, 44443}


def fail(message):
    print("check: " + message, file=sys.stderr)
    return 1


def ip_num(text):
    parts = text.split(".")
    if len(parts) != 4:
        raise ValueError(text)
    number = 0
    for part in parts:
        if not part.isdigit():
            raise ValueError(text)
        value = int(part)
        if value > 255:
            raise ValueError(text)
        number = (number << 8) + value
    return number


def cidr_bounds(cidr):
    if "/" not in cidr:
        raise ValueError(cidr)
    address, bits_text = cidr.split("/", 1)
    if not bits_text.isdigit():
        raise ValueError(cidr)
    bits = int(bits_text)
    if bits > 32:
        raise ValueError(cidr)
    size = 1 << (32 - bits)
    start = ip_num(address) & ~(size - 1)
    return start, start + size - 1


def overlaps(left, right):
    left_start, left_end = cidr_bounds(left)
    right_start, right_end = cidr_bounds(right)
    return not (left_end < right_start or right_end < left_start)


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        try:
            return json.load(handle)
        except json.JSONDecodeError as exc:
            raise ValueError("malformed json") from exc


def tcp_entry(config, port):
    tcp = config.get("TCP")
    if not isinstance(tcp, dict):
        raise ValueError("TCP table missing")
    entry = tcp.get(str(port))
    if entry is None:
        entry = tcp.get(port)
    return entry


def handlers_of(config, host):
    web = config.get("Web")
    if not isinstance(web, dict) or host not in web:
        raise ValueError("web host missing: " + host)
    handlers = web[host].get("Handlers")
    if not isinstance(handlers, dict):
        raise ValueError("handlers missing: " + host)
    return handlers


def check_before(config):
    handlers = handlers_of(config, HOST_443)
    if set(handlers) != {"/"}:
        raise ValueError("443 handlers are not only /")
    if handlers["/"].get("Proxy") != PROXY_443:
        raise ValueError("443 root proxy is not 127.0.0.1:8088")
    funnel = config.get("AllowFunnel")
    if not isinstance(funnel, dict) or funnel.get(HOST_443) is not True:
        raise ValueError("443 funnel is not exactly true")
    for key, value in funnel.items():
        if key != HOST_443 and value is True:
            raise ValueError("another funnel is enabled")
    web = config["Web"]
    if HOST_44443 in web or any(str(key).endswith(":44443") for key in web):
        raise ValueError("44443 is already served")
    https = tcp_entry(config, 443)
    if not isinstance(https, dict) or https.get("HTTPS") is not True:
        raise ValueError("443 TCP https is not true")
    if tcp_entry(config, 44443) is not None:
        raise ValueError("44443 tcp is already present")


def check_after(before, after):
    check_before(before)
    if before["Web"][HOST_443] != after["Web"][HOST_443]:
        raise ValueError("443 web config changed")
    if after.get("AllowFunnel", {}).get(HOST_443) is not True:
        raise ValueError("443 funnel changed")
    before_funnel = {key: value for key, value in before.get("AllowFunnel", {}).items() if key != HOST_44443}
    after_funnel = {key: value for key, value in after.get("AllowFunnel", {}).items() if key != HOST_44443}
    if before_funnel != after_funnel:
        raise ValueError("funnel config changed beyond 44443")
    if after.get("AllowFunnel", {}).get(HOST_44443) is True:
        raise ValueError("44443 funnel is enabled")
    before_web = set(before["Web"])
    after_web = set(after["Web"])
    if after_web - before_web != {HOST_44443} or before_web - after_web:
        raise ValueError("web hosts changed beyond 44443")
    added = handlers_of(after, HOST_44443)
    if set(added) != {"/mcp"} or added["/mcp"].get("Proxy") != PROXY_44443:
        raise ValueError("44443 is not only /mcp to 127.0.0.1:12789/mcp")
    before_tcp = dict(before.get("TCP", {}))
    after_tcp = dict(after.get("TCP", {}))
    after_new = tcp_entry(after, 44443)
    if not isinstance(after_new, dict) or after_new.get("HTTPS") is not True:
        raise ValueError("44443 tcp https is not true")
    after_tcp.pop("44443", None)
    after_tcp.pop(44443, None)
    if before_tcp != after_tcp:
        raise ValueError("tcp config changed beyond 44443")


def local_port(address):
    if address.startswith("["):
        end = address.rfind("]:")
        if end < 0:
            raise ValueError(address)
        port = address[end + 2 :]
    else:
        if ":" not in address:
            raise ValueError(address)
        port = address.rsplit(":", 1)[1]
    if not port.isdigit():
        raise ValueError(address)
    return int(port)


def check_ports(text):
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        raise ValueError("netstat output is empty")
    header = next((line for line in lines if line.startswith("Proto")), "")
    if "Local Address" not in header or "State" not in header:
        raise ValueError("netstat header was not recognized")
    for line in lines:
        if line.startswith("Active ") or line.startswith("Proto"):
            continue
        fields = line.split()
        if not fields:
            continue
        if fields[0] not in {"tcp", "tcp6", "udp", "udp6"}:
            raise ValueError("unrecognized netstat row")
        if len(fields) < 4:
            raise ValueError("short netstat row")
        port = local_port(fields[3])
        if port in BLOCKED_PORTS:
            raise ValueError("port %s is listening" % port)


def subnets_from_networks(payload):
    if isinstance(payload, dict):
        payload = [payload]
    if not isinstance(payload, list) or not payload:
        raise ValueError("docker network inspect is empty")
    found = []
    for network in payload:
        if not isinstance(network, dict) or "Name" not in network:
            raise ValueError("network record is malformed")
        ipam = network.get("IPAM") or {}
        if not isinstance(ipam, dict):
            raise ValueError("IPAM is malformed")
        config = ipam.get("Config")
        if config is None:
            continue
        if not isinstance(config, list):
            raise ValueError("IPAM config is malformed")
        for item in config:
            if not isinstance(item, dict) or "Subnet" not in item:
                raise ValueError("subnet record is malformed")
            cidr_bounds(item["Subnet"])
            found.append(item["Subnet"])
    return found


def subnets_from_ip_route(text):
    if not text.strip():
        raise ValueError("ip route output is empty")
    found = []
    for line in text.splitlines():
        if not line.strip():
            continue
        first = line.split()[0]
        if first == "default":
            continue
        if first in {"blackhole", "unreachable", "throw", "prohibit"}:
            if len(line.split()) < 2:
                raise ValueError("unparsed route")
            first = line.split()[1]
        if "/" not in first:
            ip_num(first)
            first = first + "/32"
        cidr_bounds(first)
        found.append(first)
    return found


def mask_bits(mask):
    number = ip_num(mask)
    bits = 0
    seen_zero = False
    for shift in range(31, -1, -1):
        bit = (number >> shift) & 1
        if bit:
            if seen_zero:
                raise ValueError(mask)
            bits += 1
        else:
            seen_zero = True
    return bits


def subnets_from_netstat_route(text):
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 2 or not lines[0].startswith("Destination"):
        raise ValueError("route table header was not recognized")
    found = []
    for line in lines[1:]:
        fields = line.split()
        if len(fields) < 3:
            raise ValueError("short route row")
        destination, _gateway, mask = fields[0], fields[1], fields[2]
        if destination == "0.0.0.0" and mask == "0.0.0.0":
            continue
        found.append(destination + "/" + str(mask_bits(mask)))
    return found


def check_subnets(networks_path, routes_path, kind):
    with open(networks_path, "r", encoding="utf-8") as handle:
        networks = json.load(handle)
    found = subnets_from_networks(networks)
    route_text = open(routes_path, "r", encoding="utf-8").read()
    if kind == "ip":
        found.extend(subnets_from_ip_route(route_text))
    elif kind == "netstat":
        found.extend(subnets_from_netstat_route(route_text))
    else:
        raise ValueError("unknown route kind")
    for cidr in found:
        if overlaps(SUBNET, cidr):
            raise ValueError("subnet overlaps " + cidr)


def check_names(path, forbidden):
    text = open(path, "r", encoding="utf-8").read()
    for line in text.splitlines():
        if line.strip() == forbidden:
            raise ValueError(forbidden + " already exists")


def check_projects(path):
    payload = load_json(path)
    if isinstance(payload, dict):
        payload = [payload]
    if not isinstance(payload, list):
        raise ValueError("compose project list is malformed")
    for item in payload:
        if not isinstance(item, dict):
            raise ValueError("compose project is malformed")
        name = item.get("Name", item.get("name"))
        if name == "wa-readonly-2":
            raise ValueError("compose project wa-readonly-2 already exists")


def main(argv):
    try:
        command = argv[1]
        if command == "ports":
            check_ports(open(argv[2], "r", encoding="utf-8").read())
        elif command == "subnets":
            check_subnets(argv[2], argv[3], argv[4])
        elif command == "serve-before":
            check_before(load_json(argv[2]))
        elif command == "serve-after":
            check_after(load_json(argv[2]), load_json(argv[3]))
        elif command == "names":
            check_names(argv[2], argv[3])
        elif command == "projects":
            check_projects(argv[2])
        else:
            raise ValueError("unknown command")
    except (ValueError, KeyError, IndexError, OSError, json.JSONDecodeError) as exc:
        return fail(str(exc) or exc.__class__.__name__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
