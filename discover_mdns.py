"""Read-only AirPlay discovery using only Python's standard library."""
import argparse
import json
from pathlib import Path
import socket
import struct
import time


def dns_name(data, offset):
    parts, end, seen = [], None, set()
    while True:
        if offset in seen or offset >= len(data):
            raise ValueError('Invalid DNS name')
        seen.add(offset)
        length = data[offset]
        if length & 0xC0 == 0xC0:
            if end is None:
                end = offset + 2
            offset = ((length & 0x3F) << 8) | data[offset + 1]
        elif length == 0:
            return '.'.join(parts), end or offset + 1
        else:
            offset += 1
            parts.append(data[offset:offset + length].decode('utf-8', 'replace'))
            offset += length


def records(data):
    _, _, nq, na, ns, ar = struct.unpack_from('!6H', data)
    offset = 12
    for _ in range(nq):
        _, offset = dns_name(data, offset)
        offset += 4
    for _ in range(na + ns + ar):
        name, offset = dns_name(data, offset)
        kind, _, ttl, length = struct.unpack_from('!HHIH', data, offset)
        offset += 10
        raw = data[offset:offset + length]
        value = None
        if kind == 12:
            value, _ = dns_name(data, offset)
        elif kind == 33:
            _, _, port = struct.unpack_from('!HHH', raw)
            host, _ = dns_name(data, offset + 6)
            value = {'host': host, 'port': port}
        elif kind == 1:
            value = socket.inet_ntoa(raw)
        elif kind == 16:
            value, pos = {}, 0
            while pos < len(raw):
                size = raw[pos]
                entry = raw[pos + 1:pos + 1 + size].decode('utf-8', 'replace')
                key, _, val = entry.partition('=')
                value[key] = val
                pos += size + 1
        if value is not None:
            yield {'name': name, 'type': kind, 'ttl': ttl, 'value': value}
        offset += length


def query(name, unicast=True):
    encoded = b''.join(bytes([len(p)]) + p.encode() for p in name.split('.')) + b'\0'
    # Request unicast replies; also listen for multicast responses.
    return struct.pack('!6H', 0, 0, 1, 0, 0, 0) + encoded + struct.pack('!HH', 12, 0x8001 if unicast else 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--interface', required=True, help='Local LAN IPv4 address')
    parser.add_argument('--seconds', type=float, default=15)
    parser.add_argument('--host', help='Also query a known device IPv4 address directly')
    args = parser.parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(('', 5353))
    except OSError:
        sock.bind((args.interface, 0))
    membership = socket.inet_aton('224.0.0.251') + socket.inet_aton(args.interface)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(args.interface))
    sock.settimeout(0.5)
    found, deadline, next_query = {}, time.monotonic() + args.seconds, 0
    while time.monotonic() < deadline:
        if time.monotonic() >= next_query:
            for service in ('_airplay._tcp.local', '_raop._tcp.local'):
                sock.sendto(query(service), ('224.0.0.251', 5353))
                sock.sendto(query(service, False), ('224.0.0.251', 5353))
                if args.host:
                    sock.sendto(query(service), (args.host, 5353))
            next_query = time.monotonic() + 3
        try:
            data, source = sock.recvfrom(65535)
            for item in records(data):
                item['source'] = source[0]
                found[json.dumps(item, sort_keys=True)] = item
        except socket.timeout:
            continue
        except (ValueError, IndexError, struct.error):
            continue
    sock.close()
    result = {'interface': args.interface, 'records': list(found.values())}
    Path('artifacts').mkdir(exist_ok=True)
    Path('artifacts/discovery.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    for item in found.values():
        if item['type'] == 33 and any(s in item['name'] for s in ('_airplay.', '_raop.')):
            print(json.dumps(item, ensure_ascii=True))
    print(f'Received {len(found)} unique records. Saved artifacts/discovery.json')


if __name__ == '__main__':
    main()
