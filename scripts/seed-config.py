#!/usr/bin/env python3
"""Make a seed config.boot from a VyOS default config (out/vyos-pi.config.boot.default,
or vyos-pi/config.boot.default on the image's FAT partition).

  scripts/seed-config.py DEFAULT OUT [--hostname NAME] [--ssh-key FILE]
      [--password-hash HASH] [--wan IF[=MAC]] [--lan IF[=MAC]] [--mgmt IF[=MAC]]
      [--lan-address 192.168.1.1/24] [--dhcp-range 100-199] [--domain lan]
      [--ids IF[,IF...]]

--ssh-key     enable SSH for user vyos with the public key(s) in FILE (key only:
              password login over SSH is turned off when a key is given)
--password-hash  replace user vyos's password (a crypt hash: mkpasswd -m sha-512)
--wan IF[=MAC]   uplink: DHCP client, NAT (masquerade) out of it, nothing
                 allowed in. With =MAC, the name is pinned to that NIC.
--lan IF[=MAC]   inside network: --lan-address on it, DHCP server, DNS
                 forwarder, SSH, routed to the WAN
--mgmt IF[=MAC]  management port: DHCP client, SSH and ping allowed in, not
                 routed (the VM tests reach the router this way)

--ids IF,...     Suricata on those interfaces (IDS: af-packet capture, alerts
                 in /var/log/suricata/eve.json), with the address and port
                 groups the ET Open rules use (HOME_NET = the LAN, or RFC 1918
                 without --lan). Fetch the rules once it is up: "update
                 suricata". Off unless given. IPS mode: see the README.

With --lan and --wan this is a small home router: stateful firewall (forward:
LAN -> anywhere; input: LAN, management, ping and loopback), source NAT, Kea
DHCP for the LAN, PowerDNS recursor forwarding to the WAN's DNS servers.

NIC names: VyOS names NICs by the slot they sit in and keeps that mapping in
/config/interface-mapping.json. A "hw-id" (MAC) in a config whose interfaces
version predates that (interfaces@34) is turned into such a mapping when the
config is loaded. When any MAC is given, this writes hw-id nodes and, if the
default config is already past that version, marks the interfaces section as
version 34 so VyOS's own migration (interfaces/34-to-35) pins the names.

Put OUT on the image's FAT partition as vyos-pi/config.boot; the boot hook
installs it on the next boot.
"""
import argparse
import ipaddress
import re
import sys


class Node(dict):
    """config.boot tree: key -> Node (a "name {" block) or list of values (leaf)."""


def parse(text):
    root = Node()
    stack = [root]
    body, footer = [], []
    for line in text.splitlines():
        (footer if line.startswith('//') or footer else body).append(line)
    for raw in body:
        line = raw.strip()
        if not line or line.startswith('/*'):
            continue
        if line.endswith('{'):
            node = stack[-1].setdefault(line[:-1].strip(), Node())
            stack.append(node)
        elif line == '}':
            stack.pop()
        else:
            name, _, value = line.partition(' ')
            value = value.strip()
            if not value:
                value = None  # a valueless leaf
            elif len(value) >= 2 and value[0] == value[-1] == '"':
                value = value[1:-1]
            stack[-1].setdefault(name, []).append(value)
    return root, '\n'.join(footer)


def dump(node, indent=0):
    out = []
    pad = '    ' * indent
    for key, val in node.items():
        if isinstance(val, Node):
            out.append(f'{pad}{key} {{')
            out.extend(dump(val, indent + 1))
            out.append(f'{pad}}}')
        else:
            for v in val:
                out.append(f'{pad}{key}' if v is None else f'{pad}{key} "{v}"')
    return out


def at(node, *path):
    for p in path:
        node = node.setdefault(p, Node())
    return node


def leaf(node, path, *values):
    *parents, name = path
    at(node, *parents)[name] = list(values)


def nic(spec):
    name, _, mac = spec.partition('=')
    if not re.fullmatch(r'eth\d+', name):
        raise SystemExit(f'{name}: expected an ethernet name like eth0')
    if mac and not re.fullmatch(r'([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', mac):
        raise SystemExit(f'{mac}: not a MAC address')
    return name, mac.lower()


ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
ap.add_argument('default')
ap.add_argument('out')
ap.add_argument('--hostname')
ap.add_argument('--ssh-key')
ap.add_argument('--password-hash')
ap.add_argument('--wan', type=nic)
ap.add_argument('--lan', type=nic)
ap.add_argument('--mgmt', type=nic)
ap.add_argument('--lan-address', default='192.168.1.1/24')
ap.add_argument('--dhcp-range', default='100-199')
ap.add_argument('--domain', default='lan')
ap.add_argument('--ids', type=lambda v: [nic(x)[0] for x in v.split(',')])
a = ap.parse_args()

cfg, footer = parse(open(a.default).read())
if 'vyos-config-version' not in footer:
    sys.exit(f'{a.default} has no version footer ("// vyos-config-version: ..."); '
             'VyOS would treat the seed as an ancient config')

system = at(cfg, 'system')
if a.hostname:
    leaf(system, ['host-name'], a.hostname)
user = at(system, 'login', 'user vyos', 'authentication')
if a.password_hash:
    leaf(user, ['encrypted-password'], a.password_hash)
    leaf(user, ['plaintext-password'], '')
ssh_on = bool(a.ssh_key or a.lan or a.mgmt)
if a.ssh_key:
    for i, line in enumerate(l for l in open(a.ssh_key).read().splitlines() if l.strip()):
        parts = line.split()
        if len(parts) < 2:
            sys.exit(f'{a.ssh_key}: not an OpenSSH public key line')
        ktype, key = parts[0], parts[1]
        comment = re.sub(r'[^A-Za-z0-9._@-]', '-', parts[2] if len(parts) > 2 else f'key{i}')
        k = at(user, f'public-keys {comment}')
        leaf(k, ['key'], key)
        leaf(k, ['type'], ktype)
if ssh_on:
    ssh = at(cfg, 'service', 'ssh')
    leaf(ssh, ['port'], '22')
    if a.ssh_key:
        leaf(ssh, ['disable-password-authentication'], None)

pinned = False
eth = lambda name: at(cfg, 'interfaces', f'ethernet {name}')
for role, spec in (('WAN', a.wan), ('LAN', a.lan), ('MGMT', a.mgmt)):
    if not spec:
        continue
    name, mac = spec
    e = eth(name)
    leaf(e, ['description'], role)
    if mac:
        leaf(e, ['hw-id'], mac)
        pinned = True
    if role in ('WAN', 'MGMT'):
        leaf(e, ['address'], 'dhcp')
    if role == 'MGMT':
        # its DHCP must not hand the router a default route or DNS servers
        leaf(e, ['dhcp-options', 'no-default-route'], None)

if a.lan:
    lan = a.lan[0]
    iface = ipaddress.ip_interface(a.lan_address)
    net, gw = iface.network, str(iface.ip)
    leaf(eth(lan), ['address'], str(iface))
    lo, hi = (int(x) for x in a.dhcp_range.split('-'))
    sub = at(cfg, 'service', 'dhcp-server', 'shared-network-name LAN', f'subnet {net}')
    leaf(sub, ['subnet-id'], '1')
    leaf(sub, ['option', 'default-router'], gw)
    leaf(sub, ['option', 'name-server'], gw)
    leaf(sub, ['option', 'domain-name'], a.domain)
    leaf(sub, ['range 0', 'start'], str(net.network_address + lo))
    leaf(sub, ['range 0', 'stop'], str(net.network_address + hi))
    dns = at(cfg, 'service', 'dns', 'forwarding')
    leaf(dns, ['allow-from'], str(net))
    leaf(dns, ['listen-address'], gw)
    leaf(dns, ['cache-size'], '10000')
    if a.wan:
        # forward to the DNS servers the WAN's DHCP lease names
        leaf(dns, ['system'], None)
        leaf(system, ['name-server'], a.wan[0])

if a.lan or a.wan or a.mgmt:
    fw = at(cfg, 'firewall')
    sp = at(fw, 'global-options', 'state-policy')
    leaf(sp, ['established', 'action'], 'accept')
    leaf(sp, ['related', 'action'], 'accept')
    leaf(sp, ['invalid', 'action'], 'drop')
    for role, spec in (('WAN', a.wan), ('LAN', a.lan), ('MGMT', a.mgmt)):
        if spec:
            leaf(fw, ['group', f'interface-group {role}', 'interface'], spec[0])
    for fam, icmp in (('ipv4', 'icmp'), ('ipv6', 'ipv6-icmp')):
        inp = at(fw, fam, 'input', 'filter')
        leaf(inp, ['default-action'], 'drop')
        rules = [('lo', None, None)]
        rules += [('group', 'LAN', None)] if a.lan else []
        rules += [('group', 'MGMT', None)] if a.mgmt and fam == 'ipv4' else []
        rules += [(None, None, icmp)]
        for i, (kind, val, proto) in enumerate(rules, 1):
            r = at(inp, f'rule {i * 10}')
            leaf(r, ['action'], 'accept')
            if kind == 'lo':
                leaf(r, ['inbound-interface', 'name'], 'lo')
                leaf(r, ['description'], 'loopback')
            elif kind == 'group':
                leaf(r, ['inbound-interface', 'group'], val)
                leaf(r, ['description'], f'from {val}')
            else:
                leaf(r, ['protocol'], proto)
                leaf(r, ['description'], 'ping and ICMP errors')
        if fam == 'ipv6' and a.wan:
            r = at(inp, 'rule 100')
            leaf(r, ['action'], 'accept')
            leaf(r, ['protocol'], 'udp')
            leaf(r, ['destination', 'port'], '546')
            leaf(r, ['inbound-interface', 'group'], 'WAN')
            leaf(r, ['description'], 'DHCPv6 client')
        fwd = at(fw, fam, 'forward', 'filter')
        leaf(fwd, ['default-action'], 'drop')
        if a.lan:
            r = at(fwd, 'rule 10')
            leaf(r, ['action'], 'accept')
            leaf(r, ['inbound-interface', 'group'], 'LAN')
            leaf(r, ['description'], 'LAN to anywhere')

if a.lan and a.wan:
    rule = at(cfg, 'nat', 'source', 'rule 100')
    leaf(rule, ['outbound-interface', 'name'], a.wan[0])
    leaf(rule, ['source', 'address'], str(ipaddress.ip_interface(a.lan_address).network))
    leaf(rule, ['translation', 'address'], 'masquerade')
    leaf(rule, ['description'], 'LAN to the internet')

if a.ids:
    sur = at(cfg, 'service', 'suricata')
    leaf(sur, ['interface'], *a.ids)
    home = [str(ipaddress.ip_interface(a.lan_address).network)] if a.lan else \
        ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
    leaf(sur, ['address-group home-net', 'address'], *home)
    leaf(sur, ['address-group external-net', 'group'], '!home-net')
    # the server/client groups ET Open references, all the home network
    for g in ('http-servers', 'smtp-servers', 'sql-servers', 'dns-servers', 'telnet-servers',
              'aim-servers', 'dc-servers', 'dnp3-server', 'dnp3-client', 'modbus-client',
              'modbus-server', 'enip-client', 'enip-server'):
        leaf(sur, [f'address-group {g}', 'group'], 'home-net')
    ports = {'http-ports': ['80'], 'oracle-ports': ['1521'], 'ssh-ports': ['22'],
             'dnp3-ports': ['20000'], 'modbus-ports': ['502'], 'ftp-ports': ['21'],
             'geneve-ports': ['6081'], 'vxlan-ports': ['4789'], 'teredo-ports': ['3544']}
    for g, p in ports.items():
        leaf(sur, [f'port-group {g}', 'port'], *p)
    leaf(sur, ['port-group shellcode-ports', 'group'], '!http-ports')
    leaf(sur, ['port-group file-data-ports', 'group'], 'http-ports')
    leaf(sur, ['port-group file-data-ports', 'port'], '110', '143')
    leaf(sur, ['log', 'eve', 'filename'], 'eve.json')
    leaf(sur, ['log', 'eve', 'type'], 'alert', 'drop', 'anomaly', 'http', 'dns', 'tls')

if pinned:
    m = re.search(r'interfaces@(\d+)', footer)
    if m and int(m.group(1)) >= 35:
        footer = footer.replace(m.group(0), 'interfaces@34')

with open(a.out, 'w') as f:
    f.write('\n'.join(dump(cfg)) + '\n' + footer + '\n')
