#!/usr/bin/env python3
"""Translate an OPNsense config.xml into a VyOS config.boot (a starting point).

  scripts/opnsense-to-vyos.py CONFIG.XML DEFAULT OUT --if wan=eth0[=MAC] --if lan=eth1[=MAC] ...
      [--hostname NAME] [--ssh-key FILE] [--no-import-ssh-keys]
      [--dhcp auto|kea|dhcpd|none] [--notes FILE]

DEFAULT is a VyOS default config with a version footer (the image's
vyos-pi/config.boot.default, or the release's vyos-pi.config.boot.default):
its system settings are kept and its footer tells VyOS which version to
migrate from. --if maps each OPNsense interface (wan, lan, opt1, ...) to a
VyOS ethernet name; with =MAC the name is pinned to that NIC (as
scripts/seed-config.py does). Every OPNsense interface with an address must
be mapped.

What it translates (the common sections of a home router):

  interfaces      static/DHCP IPv4, DHCPv6 + prefix delegation (track6), VLANs,
                  spoofed MAC, MTU, descriptions
  aliases         host/network -> address/network-group, port -> port-group,
                  mac -> mac-group, urltable -> remote-group (URL fetched by VyOS)
  filter rules    the MVC rules (Firewall > Rules, by sequence) then the legacy
                  ones, first match wins, into VyOS's forward and input chains;
                  block-private/bogon networks on the WAN
  NAT             port forwards -> nat destination (+ a forward rule for
                  DNAT'd traffic); outbound automatic/hybrid/manual -> nat source
  DHCP            Kea or ISC dhcpd (whichever is enabled): subnets, ranges,
                  options, static reservations -> service dhcp-server (Kea)
  DNS             Unbound -> PowerDNS recursor (service dns forwarding),
                  host overrides -> static-host-mapping
  WireGuard       instances and peers -> interfaces wireguard
  NetFlow         -> system flow-accounting
  system          domain, time zone, NTP servers, syslog remotes, SSH
                  (root's authorized keys become user vyos's)

  IDS             Suricata -> service suricata (IDS, alerts) + daily rule update

What it does not (listed in the notes file, with what to do instead):
IPS (inline blocking), OPNsense's IDS ruleset/policy choices, DNS blocklists,
traffic shaper, monit, captive portal, OpenVPN, IPsec, GeoIP aliases, policy
routing (gateway on a rule), NAT reflection.

The output is a starting point for review, not something to load blind: read
the notes, check the interface mapping, and test it (scripts/seed-config.py's
README section shows how to seed a config.boot onto the image).
"""
import argparse
import base64
import ipaddress
import re
import sys
import xml.etree.ElementTree as ET


class Node(dict):
    """config.boot tree: key -> Node (a "name {" block) or list of values (leaf)."""


def parse_boot(text):
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
            stack.append(stack[-1].setdefault(line[:-1].strip(), Node()))
        elif line == '}':
            stack.pop()
        else:
            name, _, value = line.partition(' ')
            value = value.strip()
            if not value:
                value = None
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


def add(node, path, value):
    *parents, name = path
    vals = at(node, *parents).setdefault(name, [])
    if value not in vals:
        vals.append(value)


def safe_name(text, fallback):
    name = re.sub(r'[^A-Za-z0-9_.-]+', '-', (text or '').strip()).strip('-.')
    return name[:60] or fallback


def text(e, path, default=''):
    if e is None:
        return default
    v = e.findtext(path)
    return v.strip() if v is not None else default


def split_list(v):
    return [x.strip() for x in re.split(r'[\n,]', v or '') if x.strip()]


class Notes:
    def __init__(self):
        self.items = []

    def __call__(self, section, msg):
        self.items.append((section, msg))

    def render(self):
        out = ['Translation notes (opnsense-to-vyos.py)', '']
        for section, msg in self.items:
            out.append(f'- [{section}] {msg}')
        return '\n'.join(out) + '\n'


PROTO = {'tcp': 'tcp', 'udp': 'udp', 'tcp/udp': 'tcp_udp', 'icmp': 'icmp',
         'ipv6-icmp': 'ipv6-icmp', 'icmpv6': 'ipv6-icmp', 'gre': 'gre', 'esp': 'esp',
         'ah': 'ah', 'igmp': 'igmp', 'ospf': 'ospf', 'carp': 'vrrp', 'pim': 'pim'}
BOGONS4 = ['0.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '192.0.0.0/24',
           '192.0.2.0/24', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24',
           '224.0.0.0/4', '240.0.0.0/4']
PRIVATE4 = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']


class Converter:
    def __init__(self, xml_root, cfg, args, notes):
        self.x = xml_root
        self.cfg = cfg
        self.a = args
        self.note = notes
        self.ifmap = {}       # opnsense interface key -> vyos name (eth1, eth1.10, wg0)
        self.ifmac = {}       # vyos eth name -> MAC for hw-id
        self.ifnet = {}       # opnsense key -> IPv4Interface (static only)
        self.ifdesc = {}      # opnsense key -> description
        self.wan = []         # opnsense keys of WAN-like interfaces
        self.aliases = {}     # alias name -> (type, enabled)
        self.wg_ifaces = []   # vyos wireguard names
        self.wg_nets = []     # tunnel networks
        self.router_ips = set()
        self.pinned = False
        self.ifgroups = {}    # frozenset(vyos names) -> group name

    # ---------------------------------------------------------- interfaces
    def interfaces(self):
        maps = {}
        for spec in self.a.iface or []:
            key, _, rest = spec.partition('=')
            name, _, mac = rest.partition('=')
            if not re.fullmatch(r'eth\d+', name or ''):
                raise SystemExit(f'--if {spec}: expected KEY=ethN[=MAC]')
            if mac and not re.fullmatch(r'([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', mac):
                raise SystemExit(f'--if {spec}: {mac} is not a MAC address')
            maps[key] = (name, mac.lower())
        ifs = self.x.find('interfaces')
        vlans = {text(v, 'vlanif'): v for v in self.x.findall('vlans/vlan') if text(v, 'vlanif')}
        phys = {}             # opnsense physical device -> vyos eth name
        for key, (name, mac) in maps.items():
            e = ifs.find(key) if ifs is not None else None
            if e is None:
                raise SystemExit(f'--if {key}: no such interface in the OPNsense config')
            dev = text(e, 'if')
            if dev not in vlans:
                phys[dev] = name
                if mac:
                    self.ifmac[name] = mac
        unmapped = []
        for e in list(ifs) if ifs is not None else []:
            key, dev = e.tag, text(e, 'if')
            if key == 'lo0' or text(e, 'virtual') == '1' or text(e, 'type') == 'group':
                continue
            if text(e, 'enable') != '1' and key not in maps:
                continue
            if dev in vlans:
                v = vlans[dev]
                parent = phys.get(text(v, 'if'))
                if not parent:
                    self.note('interfaces', f'{key}: VLAN {text(v, "tag")} on {text(v, "if")}, '
                              'whose parent is not mapped with --if; skipped')
                    continue
                vname = f'{parent}.{text(v, "tag")}'
                node = at(self.cfg, 'interfaces', f'ethernet {parent}', f'vif {text(v, "tag")}')
            elif key in maps:
                vname = maps[key][0]
                node = at(self.cfg, 'interfaces', f'ethernet {vname}')
            else:
                if text(e, 'ipaddr') or text(e, 'ipaddrv6'):
                    unmapped.append(key)
                continue
            self.ifmap[key] = vname
            desc = text(e, 'descr') or key.upper()
            self.ifdesc[key] = safe_name(desc, key.upper()).upper()
            leaf(node, ['description'], desc)
            if vname in self.ifmac:
                leaf(node, ['hw-id'], self.ifmac[vname])
                self.pinned = True
            if text(e, 'enable') != '1':
                leaf(node, ['disable'], None)
            ip, sub = text(e, 'ipaddr'), text(e, 'subnet')
            if ip == 'dhcp':
                leaf(node, ['address'], 'dhcp')
                self.wan.append(key)
            elif ip and sub:
                iface = ipaddress.ip_interface(f'{ip}/{sub}')
                add(node, ['address'], str(iface))
                self.ifnet[key] = iface
                self.router_ips.add(iface.ip)
            elif ip in ('pppoe', 'pptp', 'l2tp'):
                self.note('interfaces', f'{key}: {ip} uplink not translated (VyOS: interfaces pppoe)')
            if text(e, 'gateway') and key not in self.wan:
                self.wan.append(key)
            if text(e, 'spoofmac'):
                leaf(node, ['mac'], text(e, 'spoofmac').lower())
            if text(e, 'mtu'):
                leaf(node, ['mtu'], text(e, 'mtu'))
            if text(e, 'blockpriv') == '1':
                self.block_priv = getattr(self, 'block_priv', []) + [key]
            if text(e, 'blockbogons') == '1':
                self.block_bogons = getattr(self, 'block_bogons', []) + [key]
        if unmapped:
            raise SystemExit('map these OPNsense interfaces with --if KEY=ethN: ' + ', '.join(unmapped))
        if not self.wan and 'wan' in self.ifmap:
            self.wan.append('wan')
        self.ipv6()

    def ipv6(self):
        ifs = self.x.find('interfaces')
        pd = {}
        for e in ifs:
            key = e.tag
            if key not in self.ifmap:
                continue
            v6 = text(e, 'ipaddrv6')
            node = self.iface_node(key)
            if v6 == 'dhcp6':
                add(node, ['address'], 'dhcpv6')
            elif v6 == 'track6':
                up = text(e, 'track6-interface')
                pd.setdefault(up, []).append((key, int(text(e, 'track6-prefix-id') or '0', 0)))
            elif v6 and v6 not in ('none', 'slaac') and text(e, 'subnetv6'):
                add(node, ['address'], f'{v6}/{text(e, "subnetv6")}')
            elif v6 == 'slaac':
                leaf(node, ['ipv6', 'address', 'autoconf'], None)
        for up, downs in pd.items():
            if up not in self.ifmap:
                continue
            upn = self.iface_node(up)
            length = text(ifs.find(up), 'dhcp6-ia-pd-len') or '0'
            plen = {'0': '64', '1': '63', '2': '62', '3': '61', '4': '60', '5': '59',
                    '6': '58', '7': '57', '8': '56', '16': '48'}.get(length, '64')
            leaf(upn, ['dhcpv6-options', 'pd 0', 'length'], plen)
            for key, sla in downs:
                d = at(upn, 'dhcpv6-options', 'pd 0', f'interface {self.ifmap[key]}')
                leaf(d, ['address'], '1')
                leaf(d, ['sla-id'], str(sla))
                ra = at(self.cfg, 'service', 'router-advert', f'interface {self.ifmap[key]}')
                at(ra, 'prefix ::/64')
            self.note('ipv6', f'{up}: prefix delegation /{plen} to '
                      + ', '.join(self.ifmap[k] for k, _ in downs)
                      + ' with router advertisements (check the length your ISP delegates)')

    def iface_node(self, key):
        name = self.ifmap[key]
        if name.startswith('wg'):
            return at(self.cfg, 'interfaces', f'wireguard {name}')
        if '.' in name:
            base, vid = name.split('.', 1)
            return at(self.cfg, 'interfaces', f'ethernet {base}', f'vif {vid}')
        return at(self.cfg, 'interfaces', f'ethernet {name}')

    # ---------------------------------------------------------- wireguard
    def wireguard(self):
        wg = self.x.find('OPNsense/wireguard')
        if wg is None or text(wg, 'general/enabled') != '1':
            return
        clients = {c.get('uuid'): c for c in wg.findall('client/clients/client')}
        for s in wg.findall('server/servers/server'):
            if text(s, 'enabled') != '1':
                continue
            name = f'wg{text(s, "instance", "0") or "0"}'
            self.wg_ifaces.append(name)
            node = at(self.cfg, 'interfaces', f'wireguard {name}')
            leaf(node, ['description'], text(s, 'name') or name)
            for a in split_list(text(s, 'tunneladdress')):
                iface = ipaddress.ip_interface(a)
                add(node, ['address'], str(iface))
                if iface.version == 4:
                    self.wg_nets.append(iface.network)
                    self.router_ips.add(iface.ip)
            if text(s, 'port'):
                leaf(node, ['port'], text(s, 'port'))
            if text(s, 'mtu'):
                leaf(node, ['mtu'], text(s, 'mtu'))
            if text(s, 'privkey'):
                leaf(node, ['private-key'], text(s, 'privkey'))
            for uuid in split_list(text(s, 'peers')):
                c = clients.get(uuid)
                if c is None or text(c, 'enabled') != '1':
                    continue
                p = at(node, f'peer {safe_name(text(c, "name"), "peer-" + uuid[:8])}')
                if text(c, 'pubkey'):
                    leaf(p, ['public-key'], text(c, 'pubkey'))
                if text(c, 'psk'):
                    leaf(p, ['preshared-key'], text(c, 'psk'))
                for a in split_list(text(c, 'tunneladdress')):
                    add(p, ['allowed-ips'], str(ipaddress.ip_network(a, strict=False)))
                if text(c, 'serveraddress'):
                    leaf(p, ['address'], text(c, 'serveraddress'))
                    leaf(p, ['port'], text(c, 'serverport') or '51820')
                if text(c, 'keepalive'):
                    leaf(p, ['persistent-keepalive'], text(c, 'keepalive'))
            if text(s, 'gateway') or text(s, 'dns'):
                self.note('wireguard', f'{name}: gateway/DNS settings of the instance not translated')
        if self.wg_ifaces:
            self.ifmap['wireguard'] = self.wg_ifaces[0] if len(self.wg_ifaces) == 1 else None
            self.ifdesc['wireguard'] = 'WIREGUARD'

    # ---------------------------------------------------------- aliases
    def alias_groups(self):
        fw = at(self.cfg, 'firewall')
        for a in self.x.findall('OPNsense/Firewall/Alias/aliases/alias'):
            name, typ = text(a, 'name'), text(a, 'type')
            enabled = text(a, 'enabled', '1') == '1'
            content = split_list(text(a, 'content'))
            self.aliases[name] = (typ, enabled)
            desc = text(a, 'description')
            if not enabled:
                self.note('aliases', f'{name}: disabled in OPNsense (matches nothing there); '
                          'rules that use it are written disabled')
            if typ in ('host', 'network'):
                v4 = [c for c in content if self._is_net(c, 4)]
                v6 = [c for c in content if self._is_net(c, 6)]
                other = [c for c in content if c not in v4 + v6]
                kind = 'address-group' if typ == 'host' and all('/' not in c for c in v4) else 'network-group'
                if v4:
                    g = at(fw, 'group', f'{kind} {name}')
                    for c in v4:
                        add(g, ['network' if kind == 'network-group' else 'address'],
                            str(ipaddress.ip_network(c, strict=False)) if kind == 'network-group' else c)
                    if desc:
                        leaf(g, ['description'], desc)
                if v6:
                    g = at(fw, 'group', f'ipv6-{kind} {name}')
                    for c in v6:
                        add(g, ['network' if kind == 'network-group' else 'address'], c)
                if other:
                    self.note('aliases', f'{name}: entries that are not addresses (hostnames or nested '
                              f'aliases) left out: {", ".join(other)} (VyOS: domain-group)')
                if not v4 and not v6:
                    self.aliases[name] = ('empty', enabled)
            elif typ == 'port':
                g = at(fw, 'group', f'port-group {name}')
                for c in content:
                    add(g, ['port'], c.replace(':', '-'))
            elif typ == 'mac':
                g = at(fw, 'group', f'mac-group {name}')
                for c in content:
                    add(g, ['mac-address'], c.lower())
                if desc:
                    leaf(g, ['description'], desc)
            elif typ == 'urltable':
                g = at(fw, 'group', f'remote-group {name}')
                leaf(g, ['url'], content[0] if content else '')
                freq = text(a, 'updatefreq')
                if freq:
                    secs = max(60, int(float(freq) * 86400))
                    leaf(g, ['interval'], str(secs))
                if desc:
                    leaf(g, ['description'], desc)
                if len(content) > 1:
                    self.note('aliases', f'{name}: more than one URL; only the first is used')
            elif typ == 'geoip':
                self.note('aliases', f'{name}: GeoIP alias not translated; use '
                          '"source geoip country-code XX" on the rules or a remote-group')
            else:
                self.note('aliases', f'{name}: alias type {typ} not translated')

    @staticmethod
    def _is_net(c, version):
        try:
            return ipaddress.ip_network(c, strict=False).version == version
        except ValueError:
            return False

    # ---------------------------------------------------------- firewall
    def collect_rules(self):
        rules = []
        mvc = self.x.findall('OPNsense/Firewall/Filter/rules/rule')
        indexed = sorted(enumerate(mvc), key=lambda p: (int(text(p[1], 'sequence', '0') or 0), p[0]))
        for _, r in indexed:
            rules.append({
                'enabled': text(r, 'enabled', '1') == '1',
                'action': text(r, 'action', 'pass'),
                'interfaces': split_list(text(r, 'interface')),
                'direction': text(r, 'direction', 'in'),
                'family': text(r, 'ipprotocol', 'inet'),
                'protocol': text(r, 'protocol', 'any'),
                'src': text(r, 'source_net', 'any'), 'src_not': text(r, 'source_not') == '1',
                'src_port': text(r, 'source_port'),
                'dst': text(r, 'destination_net', 'any'), 'dst_not': text(r, 'destination_not') == '1',
                'dst_port': text(r, 'destination_port'),
                'log': text(r, 'log') == '1',
                'quick': text(r, 'quick', '1') == '1',
                'gateway': text(r, 'gateway'),
                'descr': text(r, 'description'),
                'floating': text(r, 'interfacenot') == '1',
            })
        for r in self.x.findall('filter/rule'):
            def side(name):
                s = r.find(name)
                if s is None or s.find('any') is not None:
                    net = 'any'
                else:
                    net = text(s, 'network') or text(s, 'address') or 'any'
                return net, text(s, 'not') == '1', text(s, 'port')
            src, src_not, src_port = side('source')
            dst, dst_not, dst_port = side('destination')
            rules.append({
                'enabled': text(r, 'disabled') != '1',
                'action': text(r, 'type', 'pass'),
                'interfaces': split_list(text(r, 'interface')),
                'direction': text(r, 'direction', 'in') or 'in',
                'family': text(r, 'ipprotocol', 'inet'),
                'protocol': text(r, 'protocol', 'any') or 'any',
                'src': src, 'src_not': src_not, 'src_port': src_port,
                'dst': dst, 'dst_not': dst_not, 'dst_port': dst_port,
                'log': text(r, 'log') == '1',
                'quick': text(r, 'quick', '1') in ('1', 'yes') or text(r, 'floating') != 'yes',
                'gateway': text(r, 'gateway'),
                'descr': text(r, 'descr'),
                'floating': text(r, 'floating') == 'yes',
            })
        return rules

    def endpoint(self, net, negate, family, rule_ifaces):
        """-> (match dict or None if it cannot match, reaches_router: bool|None, keep_reason)"""
        bang = '!' if negate else ''
        v4 = family == 'ipv4'
        if net in ('', 'any'):
            if negate:
                return None, False
            return {}, True
        if net == '(self)':
            return ({'self': True}, True) if not negate else ({}, True)
        if net.endswith('ip') and net[:-2] in self.ifmap:
            key = net[:-2]
            if key in self.ifnet and v4 and not negate:
                return {'address': str(self.ifnet[key].ip), 'self': True}, True
            return ({'self': True}, True) if not negate else ({}, True)
        if net in self.ifmap or net == 'wireguard':
            nets = []
            if net == 'wireguard':
                nets = [str(n) for n in self.wg_nets]
            elif net in self.ifnet:
                nets = [str(self.ifnet[net].network)]
            if not v4:
                # IPv6 networks of tracked interfaces are not known in advance
                if net in rule_ifaces and not negate:
                    return {}, True
                return {'unsupported': f'IPv6 network of {net}'}, None
            if not nets:
                return {'unsupported': f'network of {net} (no static address)'}, None
            if len(nets) == 1:
                reaches = any(ip in ipaddress.ip_network(nets[0]) for ip in self.router_ips)
                return {'address': bang + nets[0]}, reaches or negate
            return {'unsupported': f'several networks for {net}'}, None
        if net in self.aliases:
            typ, enabled = self.aliases[net]
            if typ == 'empty':
                return {'unsupported': f'alias {net} has no addresses for {family}'}, None
            group = {'host': 'address-group', 'network': 'network-group', 'urltable': 'remote-group',
                     'mac': 'mac-group', 'port': None}.get(typ)
            if typ in ('host', 'network'):
                g = self.cfg.get('firewall', {}).get('group', {})
                kind = 'address-group' if f'address-group {net}' in g else 'network-group'
                if not v4:
                    kind = 'ipv6-' + kind if f'ipv6-{kind} {net}' in g else None
                    if not kind:
                        return {'unsupported': f'alias {net} has no IPv6 entries'}, None
                group = kind
            if group is None:
                return {'unsupported': f'alias {net} ({typ})'}, None
            m = {'group': (group, bang + net)}
            if not enabled:
                m['disabled_alias'] = net
            reaches = negate or typ in ('host', 'network') and self._alias_has_router(net)
            return m, reaches
        try:
            n = ipaddress.ip_network(net, strict=False)
        except ValueError:
            return {'unsupported': f'"{net}"'}, None
        if (n.version == 4) != v4:
            return None, False
        reaches = negate or any(ip in n for ip in self.router_ips)
        return {'address': bang + (str(n) if '/' in net else net)}, reaches

    def _alias_has_router(self, name):
        for a in self.x.findall('OPNsense/Firewall/Alias/aliases/alias'):
            if text(a, 'name') == name:
                for c in split_list(text(a, 'content')):
                    try:
                        n = ipaddress.ip_network(c, strict=False)
                    except ValueError:
                        continue
                    if any(ip in n for ip in self.router_ips if ip.version == n.version):
                        return True
        return False

    def inbound(self, keys):
        names = []
        for k in keys:
            if k == 'wireguard':
                names += self.wg_ifaces
            elif k in self.ifmap and self.ifmap[k]:
                names.append(self.ifmap[k])
            else:
                return None
        names = sorted(set(names))
        if len(names) == 1:
            return ('name', names[0])
        key = frozenset(names)
        if key not in self.ifgroups:
            gname = '_'.join(self.ifdesc.get(k, k.upper()) for k in keys)[:30] or 'GROUP'
            self.ifgroups[key] = gname
            g = at(self.cfg, 'firewall', 'group', f'interface-group {gname}')
            for n in names:
                add(g, ['interface'], n)
        return ('group', self.ifgroups[key])

    def firewall(self):
        fw = at(self.cfg, 'firewall')
        sp = at(fw, 'global-options', 'state-policy')
        leaf(sp, ['established', 'action'], 'accept')
        leaf(sp, ['related', 'action'], 'accept')
        leaf(sp, ['invalid', 'action'], 'drop')
        chains = {}
        for fam in ('ipv4', 'ipv6'):
            for hook in ('input', 'forward'):
                c = at(fw, fam, hook, 'filter')
                leaf(c, ['default-action'], 'drop')
                chains[(fam, hook)] = c
        num = {k: 0 for k in chains}

        def rule(fam, hook, **kw):
            num[(fam, hook)] += 10
            r = at(chains[(fam, hook)], f'rule {num[(fam, hook)]}')
            for k, v in kw.items():
                if v is None:
                    continue
                path = k.split('__')
                path = [p.replace('_', '-') for p in path]
                if isinstance(v, bool):
                    if v:
                        leaf(r, path, None)
                else:
                    leaf(r, path, v)
            return r

        # implicit rules OPNsense has, VyOS does not
        for fam in ('ipv4', 'ipv6'):
            rule(fam, 'input', action='accept', inbound_interface__name='lo', description='loopback')
        rule('ipv6', 'input', action='accept', protocol='ipv6-icmp',
             description='ICMPv6 (neighbour discovery, router advertisements)')
        rule('ipv6', 'forward', action='accept', protocol='ipv6-icmp', description='ICMPv6')
        wan_names = [self.ifmap[k] for k in self.wan if self.ifmap.get(k)]
        for k in self.wan:
            if k not in self.ifmap:
                continue
            if any(t == 'dhcp6' for t in [text(self.x.find('interfaces'), f'{k}/ipaddrv6')]):
                rule('ipv6', 'input', action='accept', protocol='udp', destination__port='546',
                     inbound_interface__name=self.ifmap[k], description=f'DHCPv6 client on {k}')
        for attr, nets, label in (('block_priv', PRIVATE4, 'private'), ('block_bogons', BOGONS4, 'bogon')):
            keys = [k for k in getattr(self, attr, []) if k in self.ifmap]
            if not keys:
                continue
            gname = 'OPN-PRIVATE' if label == 'private' else 'OPN-BOGONS'
            g = at(fw, 'group', f'network-group {gname}')
            for n in nets:
                add(g, ['network'], n)
            for k in keys:
                for hook in ('input', 'forward'):
                    rule('ipv4', hook, action='drop', inbound_interface__name=self.ifmap[k],
                         source__group__network_group=gname, description=f'Block {label} networks on {k}')
        # anti-lockout: OPNsense lets the LAN reach SSH/web GUI whatever the rules say
        websys = self.x.find('system/webgui')
        if 'lan' in self.ifmap and (websys is None or websys.find('noantilockout') is None):
            rule('ipv4', 'input', action='accept', protocol='tcp', destination__port='22',
                 inbound_interface__name=self.ifmap['lan'], description='anti-lockout: SSH from lan')
        # DHCP servers: OPNsense opens UDP 67 by itself
        for k in getattr(self, 'dhcp_ifaces', []):
            rule('ipv4', 'input', action='accept', protocol='udp', destination__port='67',
                 inbound_interface__name=self.ifmap[k], description=f'DHCP server on {k}')
        if self.has_portforwards:
            rule('ipv4', 'forward', action='accept', connection_status__nat='destination',
                 description='port forwards (nat destination)')

        for i, r in enumerate(self.collect_rules()):
            label = r['descr'] or f'{r["action"]} on {",".join(r["interfaces"]) or "floating"} (rule {i + 1})'
            if r['direction'] != 'in':
                self.note('firewall', f'"{label}": direction {r["direction"]} not translated')
                continue
            if r['floating'] or not r['interfaces']:
                self.note('firewall', f'"{label}": floating/inverted-interface rule not translated')
                continue
            inb = self.inbound(r['interfaces'])
            if inb is None:
                self.note('firewall', f'"{label}": interface {",".join(r["interfaces"])} not mapped; skipped')
                continue
            if r['gateway']:
                self.note('firewall', f'"{label}": policy routing via {r["gateway"]} not translated '
                          '(VyOS: policy route)')
            if not r['quick']:
                self.note('firewall', f'"{label}": a non-quick rule (last match wins in pf) is written '
                          'as first-match; check its position')
            fams = {'inet': ['ipv4'], 'inet6': ['ipv6'], 'inet46': ['ipv4', 'ipv6']}.get(r['family'], ['ipv4'])
            for fam in fams:
                src, src_reach = self.endpoint(r['src'], r['src_not'], fam, r['interfaces'])
                dst, dst_reach = self.endpoint(r['dst'], r['dst_not'], fam, r['interfaces'])
                if src is None or dst is None:
                    if (dst is None and r['dst_not']) or (src is None and r['src_not']):
                        self.note('firewall', f'"{label}" ({fam}): "not any" matches no address; '
                                  'written disabled (check what the rule was meant to do)')
                    else:
                        self.note('firewall', f'"{label}" ({fam}): no {fam} addresses to match; '
                                  'written disabled')
                    src = src if src is not None else {}
                    dst = dst if dst is not None else {}
                    disabled = True
                else:
                    disabled = not r['enabled']
                bad = [m['unsupported'] for m in (src, dst) if 'unsupported' in m]
                if bad:
                    self.note('firewall', f'"{label}" ({fam}): {"; ".join(bad)} not translatable; skipped')
                    continue
                for m in (src, dst):
                    if 'disabled_alias' in m:
                        disabled = True
                if dst.get('self'):
                    hooks = ['input']
                elif dst_reach is False:
                    hooks = ['forward']
                else:
                    hooks = ['forward', 'input']
                proto = r['protocol'].lower()
                proto = PROTO.get(proto, proto) if proto != 'any' else None
                if proto == 'icmp' and fam == 'ipv6':
                    proto = 'ipv6-icmp'
                for hook in hooks:
                    rr = rule(fam, hook, action={'pass': 'accept', 'block': 'drop',
                                                 'reject': 'reject'}.get(r['action'], 'drop'),
                              description=label[:255], protocol=proto,
                              log=r['log'], disable=disabled)
                    leaf(rr, ['inbound-interface', inb[0]], inb[1])
                    for side, m, port in (('source', src, r['src_port']), ('destination', dst, r['dst_port'])):
                        if 'address' in m and not (hook == 'input' and m.get('self')):
                            leaf(rr, [side, 'address'], m['address'])
                        if 'group' in m:
                            leaf(rr, [side, 'group', m['group'][0]], m['group'][1])
                        if port:
                            if port in self.aliases:
                                leaf(rr, [side, 'group', 'port-group'], port)
                            else:
                                leaf(rr, [side, 'port'], port.replace(':', '-'))
                    if (r['src_port'] or r['dst_port']) and not proto:
                        leaf(rr, ['protocol'], 'tcp_udp')

    # ---------------------------------------------------------- NAT
    def nat(self):
        nat = Node()
        n = 0
        self.has_portforwards = False
        for r in self.x.findall('nat/rule'):
            iface = text(r, 'interface', 'wan')
            if iface not in self.ifmap:
                self.note('nat', f'port forward "{text(r, "descr")}": interface {iface} not mapped; skipped')
                continue
            self.has_portforwards = True
            n += 10
            d = at(nat, 'destination', f'rule {n}')
            leaf(d, ['description'], text(r, 'descr') or f'port forward {text(dst, "port") if (dst := r.find("destination")) is not None else ""}'.strip())
            if text(r, 'disabled') == '1':
                leaf(d, ['disable'], None)
            leaf(d, ['inbound-interface', 'name'], self.ifmap[iface])
            proto = PROTO.get(text(r, 'protocol').lower(), text(r, 'protocol').lower() or None)
            if proto:
                leaf(d, ['protocol'], proto)
            dst = r.find('destination')
            dnet = text(dst, 'network') or text(dst, 'address')
            if dnet and not dnet.endswith('ip') and dnet != 'any':
                leaf(d, ['destination', 'address'], ('!' if text(dst, 'not') == '1' else '') + dnet)
            if text(dst, 'port'):
                leaf(d, ['destination', 'port'], text(dst, 'port').replace(':', '-'))
            src = r.find('source')
            snet = text(src, 'network') or text(src, 'address')
            if snet and snet != 'any':
                if snet in self.aliases:
                    self.note('nat', f'port forward "{text(r, "descr")}": source alias {snet} not translated')
                else:
                    leaf(d, ['source', 'address'], ('!' if text(src, 'not') == '1' else '') + snet)
            target = text(r, 'target')
            if target in self.aliases:
                content = [split_list(text(a, 'content')) for a in
                           self.x.findall('OPNsense/Firewall/Alias/aliases/alias') if text(a, 'name') == target]
                if content and len(content[0]) == 1:
                    target = content[0][0]
                else:
                    self.note('nat', f'port forward "{text(r, "descr")}": target alias {target} '
                              'is not a single host; fill in translation address')
            leaf(d, ['translation', 'address'], target)
            if text(r, 'local-port'):
                leaf(d, ['translation', 'port'], text(r, 'local-port'))
            if text(r, 'natreflection') not in ('', 'disable'):
                self.note('nat', f'port forward "{text(r, "descr") or text(r, "destination/port")}": NAT reflection '
                          f'({text(r, "natreflection")}) not translated (VyOS: an extra destination '
                          'rule on the LAN side plus a source rule, or split DNS)')

        mode = text(self.x, 'nat/outbound/mode', 'automatic')
        n = 0
        wans = [k for k in self.wan if k in self.ifmap]
        if mode in ('hybrid', 'advanced'):
            for r in self.x.findall('nat/outbound/rule'):
                iface = text(r, 'interface', 'wan')
                if iface not in self.ifmap:
                    continue
                n += 10
                s = at(nat, 'source', f'rule {n}')
                if text(r, 'descr'):
                    leaf(s, ['description'], text(r, 'descr'))
                if text(r, 'disabled') == '1':
                    leaf(s, ['disable'], None)
                leaf(s, ['outbound-interface', 'name'], self.ifmap[iface])
                for side in ('source', 'destination'):
                    e = r.find(side)
                    net = text(e, 'network') or text(e, 'address')
                    if e is not None and e.find('any') is None and net and net != 'any':
                        if net in self.ifnet:
                            net = str(self.ifnet[net].network)
                        leaf(s, [side, 'address'], ('!' if text(e, 'not') == '1' else '') + net)
                if text(r, 'nonat') == '1':
                    leaf(s, ['exclude'], None)
                else:
                    leaf(s, ['translation', 'address'], text(r, 'target') or 'masquerade')
                proto = text(r, 'protocol').lower()
                if proto and proto != 'any':
                    leaf(s, ['protocol'], PROTO.get(proto, proto))
        if mode in ('automatic', 'hybrid'):
            inside = [str(self.ifnet[k].network) for k in self.ifnet if k not in self.wan]
            inside += [str(x) for x in self.wg_nets]
            n = max(n, 90)
            for w in wans:
                for net in inside:
                    n += 10
                    s = at(nat, 'source', f'rule {n}')
                    leaf(s, ['description'], f'automatic outbound NAT: {net} out {w}')
                    leaf(s, ['outbound-interface', 'name'], self.ifmap[w])
                    leaf(s, ['source', 'address'], net)
                    leaf(s, ['translation', 'address'], 'masquerade')
        elif mode == 'disabled':
            self.note('nat', 'outbound NAT is disabled in OPNsense; no source NAT written')
        if nat:
            self.cfg['nat'] = nat

    # ---------------------------------------------------------- DHCP
    def dhcp(self):
        kea = self.x.find('OPNsense/Kea/dhcp4')
        kea_on = text(kea, 'general/enabled') == '1'
        isc = [e for e in self.x.findall('dhcpd/*') if text(e, 'enable') == '1']
        mode = self.a.dhcp
        if mode == 'auto':
            mode = 'kea' if kea_on else 'dhcpd' if isc else 'none'
        if kea is not None and not kea_on and len(kea.findall('reservations/reservation')):
            self.note('dhcp', f'Kea holds {len(kea.findall("reservations/reservation"))} reservations '
                      f'but is disabled; using {mode}')
        self.dhcp_ifaces = []
        if mode == 'none':
            return
        srv = at(self.cfg, 'service', 'dhcp-server')
        sid = 0
        used = set()

        seen = {}

        def mapping(sub, name, ip, mac, desc, net):
            if not ip or not mac:
                self.note('dhcp', f'reservation {ip or "?"} ({name or mac or "?"}) needs an IP and a MAC; skipped')
                return
            ipa = ipaddress.ip_address(ip)
            if ipa not in net:
                self.note('dhcp', f'reservation {ip} ({name or mac}) is outside {net}; skipped')
                return
            ips, macs = seen.setdefault(str(net), (set(), set()))
            if ip in ips or mac.lower() in macs:
                self.note('dhcp', f'reservation {ip} ({name or mac}) repeats an IP or MAC already '
                          f'reserved in {net} (Kea refuses that); skipped')
                return
            ips.add(ip)
            macs.add(mac.lower())
            nm = safe_name(name, 'host-' + ip.replace('.', '-'))
            base, k = nm, 2
            while nm.lower() in used:
                nm, k = f'{base}-{k}', k + 1
            used.add(nm.lower())
            m = at(sub, f'static-mapping {nm}')
            leaf(m, ['ip-address'], ip)
            leaf(m, ['mac'], mac.lower())
            if desc:
                leaf(m, ['description'], desc[:255])

        if mode == 'kea':
            subs = {}
            for s in kea.findall('subnets/subnet4'):
                net = ipaddress.ip_network(text(s, 'subnet'), strict=False)
                key = next((k for k, v in self.ifnet.items() if v.network == net), None)
                if key is None or key not in self.ifmap:
                    self.note('dhcp', f'Kea subnet {net}: no mapped interface has it; skipped')
                    continue
                self.dhcp_ifaces.append(key)
                sid += 1
                sub = at(srv, f'shared-network-name {self.ifdesc[key]}', f'subnet {net}')
                leaf(sub, ['subnet-id'], text(s, 'subnet_id') or str(sid))
                if text(s, 'description'):
                    leaf(sub, ['description'], text(s, 'description'))
                gw = text(s, 'option_data/routers') or str(self.ifnet[key].ip)
                leaf(sub, ['option', 'default-router'], gw)
                for ns in split_list(text(s, 'option_data/domain_name_servers')) or [gw]:
                    add(sub, ['option', 'name-server'], ns)
                for ntp in split_list(text(s, 'option_data/ntp_servers')):
                    add(sub, ['option', 'ntp-server'], ntp)
                if text(s, 'option_data/domain_name'):
                    leaf(sub, ['option', 'domain-name'], text(s, 'option_data/domain_name'))
                if text(kea, 'general/valid_lifetime'):
                    leaf(sub, ['lease'], text(kea, 'general/valid_lifetime'))
                for i, pool in enumerate(split_list(text(s, 'pools'))):
                    lo, _, hi = pool.partition('-')
                    if '/' in pool:
                        p = ipaddress.ip_network(pool, strict=False)
                        lo, hi = str(p.network_address + 1), str(p.broadcast_address - 1)
                    leaf(sub, [f'range {i}', 'start'], lo.strip())
                    leaf(sub, [f'range {i}', 'stop'], hi.strip())
                subs[s.get('uuid')] = (sub, net)
            for r in kea.findall('reservations/reservation'):
                if r.get('uuid') and text(r, 'subnet') in subs:
                    sub, net = subs[text(r, 'subnet')]
                    mapping(sub, text(r, 'hostname'), text(r, 'ip_address'), text(r, 'hw_address'),
                            text(r, 'description'), net)
        else:
            for e in isc:
                key = e.tag
                if key not in self.ifnet or key not in self.ifmap:
                    self.note('dhcp', f'dhcpd on {key}: interface has no static address or is not mapped')
                    continue
                self.dhcp_ifaces.append(key)
                sid += 1
                net = self.ifnet[key].network
                sub = at(srv, f'shared-network-name {self.ifdesc[key]}', f'subnet {net}')
                leaf(sub, ['subnet-id'], str(sid))
                gw = text(e, 'gateway') or str(self.ifnet[key].ip)
                leaf(sub, ['option', 'default-router'], gw)
                dns = [d.text.strip() for d in e.findall('dnsserver') if d.text and d.text.strip()]
                for ns in dns or [str(self.ifnet[key].ip)]:
                    add(sub, ['option', 'name-server'], ns)
                for ntp in [d.text.strip() for d in e.findall('ntpserver') if d.text and d.text.strip()]:
                    add(sub, ['option', 'ntp-server'], ntp)
                if text(e, 'domain'):
                    leaf(sub, ['option', 'domain-name'], text(e, 'domain'))
                if text(e, 'defaultleasetime'):
                    leaf(sub, ['lease'], text(e, 'defaultleasetime'))
                lo, hi = text(e, 'range/from'), text(e, 'range/to')
                if lo and hi:
                    leaf(sub, ['range 0', 'start'], lo)
                    hi_ip = ipaddress.ip_address(hi)
                    if hi_ip == net.broadcast_address or hi_ip == net.network_address:
                        self.note('dhcp', f'dhcpd on {key}: range end {hi} is not a host address; '
                                  f'ended the range at {hi_ip - 1}')
                        hi = str(hi_ip - 1)
                    leaf(sub, ['range 0', 'stop'], hi)
                for m in e.findall('staticmap'):
                    mapping(sub, text(m, 'hostname'), text(m, 'ipaddr'), text(m, 'mac'),
                            text(m, 'descr'), net)
        if not srv:
            del self.cfg['service']['dhcp-server']

    # ---------------------------------------------------------- DNS
    def dns(self):
        u = self.x.find('OPNsense/unboundplus')
        if u is None or text(u, 'general/enabled') != '1':
            if text(self.x, 'dnsmasq/enable') == '1':
                self.note('dns', 'dnsmasq DNS not translated')
            return
        fwd = at(self.cfg, 'service', 'dns', 'forwarding')
        inside = [k for k in self.ifnet if k not in self.wan]
        for k in inside:
            add(fwd, ['listen-address'], str(self.ifnet[k].ip))
            add(fwd, ['allow-from'], str(self.ifnet[k].network))
        for n in self.wg_nets:
            add(fwd, ['allow-from'], str(n))
        leaf(fwd, ['cache-size'], '10000')
        if text(u, 'general/dnssec') == '1':
            leaf(fwd, ['dnssec'], 'validate')
        servers = []
        for d in u.findall('dots/dot'):
            if text(d, 'enabled', '1') != '1':
                continue
            if text(d, 'type') == 'dot':
                self.note('dns', f'DNS over TLS to {text(d, "server")} not supported by the recursor; '
                          'forwarding to it in plain DNS instead')
            dom = text(d, 'domain')
            srv = text(d, 'server')
            if dom:
                add(fwd, [f'domain {dom}', 'name-server'], srv)
            else:
                servers.append(srv)
        for s in servers:
            add(fwd, ['name-server'], s)
        if text(u, 'forwarding/enabled') == '1' and not servers:
            leaf(fwd, ['system'], None)
            self.note('dns', 'Unbound forwards to the system DNS servers: "system" set; add '
                      '"system name-server <wan>" if the WAN learns them by DHCP')
        elif not servers:
            self.note('dns', 'Unbound resolves recursively; so does the PowerDNS recursor without '
                      'name-servers')
        for h in u.findall('hosts/host'):
            if text(h, 'enabled', '1') != '1':
                continue
            rr = text(h, 'rr', 'A')
            host, dom, ip = text(h, 'hostname'), text(h, 'domain'), text(h, 'server')
            if rr not in ('A', 'AAAA') or not ip:
                self.note('dns', f'host override {host}.{dom} ({rr}) not translated')
                continue
            fqdn = f'{host}.{dom}' if host and host != '*' else dom
            if host == '*':
                self.note('dns', f'wildcard override *.{dom} written as {dom} only')
            m = at(self.cfg, 'system', 'static-host-mapping', f'host-name {fqdn}')
            add(m, ['inet'], ip)
        for a in u.findall('aliases/alias'):
            if text(a, 'enabled', '1') == '1':
                self.note('dns', f'host alias {text(a, "hostname")}.{text(a, "domain")} not translated')
        if u.findall('dnsbl/blocklist') or text(u, 'dnsbl/enabled') == '1':
            self.note('dns', 'DNS blocklists (Unbound DNSBL) have no VyOS equivalent: point clients at '
                      'a blocker (AdGuard Home, Pi-hole) or forward to a filtering resolver')
        if text(u, 'general/regdhcp') == '1' or text(u, 'general/regdhcpstatic') == '1':
            if 'dhcp-server' in self.cfg.get('service', {}):
                leaf(self.cfg, ['service', 'dhcp-server', 'hostfile-update'], None)
            self.note('dns', 'DHCP lease registration: "service dhcp-server hostfile-update" puts '
                      'leases and reservations into /etc/hosts, which the recursor serves')

    # ---------------------------------------------------------- the rest
    def system(self):
        system = at(self.cfg, 'system')
        host = self.a.hostname or text(self.x, 'system/hostname')
        if host:
            leaf(system, ['host-name'], safe_name(host, 'vyos'))
        if text(self.x, 'system/domain'):
            leaf(system, ['domain-name'], text(self.x, 'system/domain'))
        tz = text(self.x, 'system/timezone')
        if tz:
            leaf(system, ['time-zone'], 'UTC' if tz in ('Etc/UTC', 'UTC') else tz)
        ts = split_list(text(self.x, 'system/timeservers').replace(' ', ','))
        if ts:
            ntp = at(self.cfg, 'service', 'ntp')
            for k in [k for k in ntp if k.startswith('server ')]:
                del ntp[k]
            for t in ts:
                at(ntp, f'server {t}')
        for d in self.x.findall('OPNsense/Syslog/destinations/destination'):
            if text(d, 'enabled', '1') != '1':
                continue
            r = at(system, 'syslog', f'remote {text(d, "hostname")}')
            leaf(r, ['port'], text(d, 'port') or '514')
            if text(d, 'transport', 'udp4').startswith('tcp'):
                leaf(r, ['protocol'], 'tcp')
            leaf(r, ['facility all', 'level'], 'info')
        # SSH
        ssh = self.x.find('system/ssh')
        if ssh is not None and text(ssh, 'enabled') == 'enabled':
            s = at(self.cfg, 'service', 'ssh')
            leaf(s, ['port'], text(ssh, 'port') or '22')
            for k in split_list(text(ssh, 'interfaces')):
                if k in self.ifnet:
                    add(s, ['listen-address'], str(self.ifnet[k].ip))
        keys = []
        if self.a.import_ssh_keys:
            for u in self.x.findall('system/user'):
                if text(u, 'name') == 'root' and text(u, 'authorizedkeys'):
                    try:
                        keys += base64.b64decode(text(u, 'authorizedkeys')).decode().splitlines()
                    except ValueError:
                        self.note('ssh', 'root authorized keys could not be decoded')
        if self.a.ssh_key:
            with open(self.a.ssh_key) as f:
                keys += f.read().splitlines()
        user = at(system, 'login', 'user vyos', 'authentication')
        seen = set()
        for i, line in enumerate(k for k in keys if k.strip() and not k.startswith('#')):
            parts = line.split()
            if len(parts) < 2 or parts[1] in seen:
                continue
            seen.add(parts[1])
            comment = safe_name(parts[2] if len(parts) > 2 else '', f'key{i}')
            k = at(user, f'public-keys {comment}')
            leaf(k, ['key'], parts[1])
            leaf(k, ['type'], parts[0])
        if seen:
            leaf(at(self.cfg, 'service', 'ssh'), ['disable-password-authentication'], None)

    def netflow(self):
        nf = self.x.find('OPNsense/Netflow')
        if nf is None or text(nf, 'collect/enable') != '1' and not text(nf, 'capture/targets'):
            return
        ifs = [self.ifmap[k] for k in split_list(text(nf, 'capture/interfaces')) if self.ifmap.get(k)]
        targets = split_list(text(nf, 'capture/targets'))
        if not ifs or not targets:
            return
        fa = at(self.cfg, 'system', 'flow-accounting')
        n = at(fa, 'netflow')
        for i in ifs:
            add(n, ['interface'], i)
        leaf(n, ['version'], {'v5': '5', 'v9': '9', 'ipfix': '10'}.get(text(nf, 'capture/version'), '9'))
        for t in targets:
            host, _, port = t.rpartition(':')
            leaf(n, [f'server {host}', 'port'], port or '2055')
            if host.startswith('127.'):
                self.note('netflow', f'{t} is OPNsense\'s own collector (Reporting > Insight); VyOS has '
                          'none: point the exporter at an external collector (nfcapd, ntopng, Akvorado)')
        if text(nf, 'activeTimeout'):
            leaf(n, ['active-timeout'], text(nf, 'activeTimeout'))
        if text(nf, 'inactiveTimeout'):
            leaf(n, ['inactive-timeout'], text(nf, 'inactiveTimeout'))
        if text(nf, 'capture/egress_only'):
            leaf(fa, ['enable-egress'], None)
            self.note('netflow', 'egress-only capture on ' + text(nf, 'capture/egress_only')
                      + ' approximated by enable-egress (all exporting interfaces)')

    # the variables Suricata's default suricata.yaml defines and ET Open rules use
    IDS_ADDRESS_GROUPS = ['http-servers', 'smtp-servers', 'sql-servers', 'dns-servers', 'telnet-servers',
                          'aim-servers', 'dc-servers', 'dnp3-server', 'dnp3-client', 'modbus-client',
                          'modbus-server', 'enip-client', 'enip-server']
    IDS_PORT_GROUPS = [('http-ports', ['80'], []), ('shellcode-ports', [], ['!http-ports']),
                       ('oracle-ports', ['1521'], []), ('ssh-ports', ['22'], []),
                       ('dnp3-ports', ['20000'], []), ('modbus-ports', ['502'], []),
                       ('file-data-ports', ['110', '143'], ['http-ports']), ('ftp-ports', ['21'], []),
                       ('geneve-ports', ['6081'], []), ('vxlan-ports', ['4789'], []),
                       ('teredo-ports', ['3544'], [])]

    def ids(self):
        ids = self.x.find('OPNsense/IDS/general')
        if ids is None or text(ids, 'enabled') != '1':
            return
        ifs = [self.ifmap[k] for k in split_list(text(ids, 'interfaces')) if self.ifmap.get(k)]
        if not ifs:
            self.note('ids', 'Suricata is on, but on no mapped interface; not translated')
            return
        s = at(self.cfg, 'service', 'suricata')
        for i in ifs:
            add(s, ['interface'], i)
        home = split_list(text(ids, 'homenet')) or ['192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12']
        for h in home:
            add(s, ['address-group home-net', 'address'], h)
        add(s, ['address-group external-net', 'group'], '!home-net')
        for g in self.IDS_ADDRESS_GROUPS:
            add(s, [f'address-group {g}', 'group'], 'home-net')
        for name, ports, groups in self.IDS_PORT_GROUPS:
            for port in ports:
                add(s, [f'port-group {name}', 'port'], port)
            for g in groups:
                add(s, [f'port-group {name}', 'group'], g)
        eve = at(s, 'log', 'eve')
        add(eve, ['type'], 'alert')
        for proto in ('http', 'tls'):
            if text(ids, f'eveLog/{proto}/enable') == '1':
                add(eve, ['type'], proto)
        task = at(self.cfg, 'system', 'task-scheduler', 'task suricata-update')
        leaf(task, ['interval'], '1d')
        leaf(task, ['executable', 'path'], '/usr/libexec/vyos/op_mode/update_suricata.sh')
        ips = text(ids, 'ips') == '1' or text(ids, 'mode') == 'netmap'
        self.note('ids', 'Suricata ' + ('IPS: VyOS runs Suricata as an IDS only (af-packet, alerts, '
                                        'no inline blocking)' if ips else 'IDS')
                  + f' on {", ".join(ifs)}, HOME_NET {", ".join(home)}. Rules come from '
                  'suricata-update (ET Open by default), not from OPNsense\'s ruleset and policy '
                  'choices: run "update suricata" once after the first commit; a daily task-scheduler '
                  'job keeps them current. Mind the memory on a 2-4 GB Pi')

    def gaps(self):
        x = self.x
        ts = x.find('OPNsense/TrafficShaper')
        if ts is not None and any(len(list(c)) for c in ts):
            self.note('gap', 'traffic shaper pipes/queues/rules not translated (VyOS: qos policy '
                      'shaper / fq-codel / cake)')
        if text(x, 'OPNsense/monit/general/enabled') == '1':
            self.note('gap', 'monit not translated (VyOS: service monitoring prometheus/telegraf)')
        for path, what in (('OPNsense/OpenVPN/Instances/Instance', 'OpenVPN instances'),
                           ('openvpn/openvpn-server', 'OpenVPN servers'),
                           ('OPNsense/Swanctl/Connections/Connection', 'IPsec connections'),
                           ('OPNsense/captiveportal/zones/zone', 'captive portal zones')):
            if x.findall(path):
                self.note('gap', f'{what} not translated')
        if text(x, 'snmpd/rocommunity') and text(x, 'snmpd/enable', '0') == '1':
            self.note('gap', 'SNMP not translated (VyOS: service snmp)')

    def run(self):
        self.interfaces()
        self.wireguard()
        self.alias_groups()
        self.nat()
        self.dhcp()
        self.firewall()
        self.dns()
        self.system()
        self.netflow()
        self.ids()
        self.gaps()
        if self.pinned:
            self.note('interfaces', 'NIC names pinned by hw-id: the interfaces section is marked '
                      'version 34 so VyOS turns them into its slot map on the first load')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('config_xml')
    ap.add_argument('default', help='VyOS default config.boot with a version footer')
    ap.add_argument('out')
    ap.add_argument('--if', dest='iface', action='append', metavar='KEY=ethN[=MAC]',
                    help='map an OPNsense interface (wan, lan, opt1...) to a VyOS ethernet')
    ap.add_argument('--hostname')
    ap.add_argument('--ssh-key', help='also authorise the public key(s) in this file for user vyos')
    ap.add_argument('--no-import-ssh-keys', dest='import_ssh_keys', action='store_false',
                    help="don't copy root's authorized keys from the OPNsense config")
    ap.add_argument('--dhcp', choices=['auto', 'kea', 'dhcpd', 'none'], default='auto')
    ap.add_argument('--notes', help='write the translation notes here (default: stderr)')
    a = ap.parse_args(argv)

    with open(a.default) as f:
        cfg, footer = parse_boot(f.read())
    if 'vyos-config-version' not in footer:
        raise SystemExit(f'{a.default} has no version footer ("// vyos-config-version: ...")')
    notes = Notes()
    conv = Converter(ET.parse(a.config_xml).getroot(), cfg, a, notes)
    conv.run()
    if conv.pinned:
        m = re.search(r'interfaces@(\d+)', footer)
        if m and int(m.group(1)) >= 35:
            footer = footer.replace(m.group(0), 'interfaces@34')
    with open(a.out, 'w') as f:
        f.write('\n'.join(dump(cfg)) + '\n' + footer + '\n')
    if a.notes:
        with open(a.notes, 'w') as f:
            f.write(notes.render())
    else:
        sys.stderr.write(notes.render())


if __name__ == '__main__':
    main()
