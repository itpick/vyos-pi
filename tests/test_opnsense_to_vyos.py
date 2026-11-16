"""Tests for scripts/opnsense-to-vyos.py on the synthetic sample (examples/).

  python3 -m unittest discover -s tests -v      (or: make test-scripts)
"""
import contextlib
import importlib.util
import io
import os
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, 'scripts', 'opnsense-to-vyos.py')
SAMPLE = os.path.join(ROOT, 'examples', 'opnsense-sample.config.xml')
DEFAULT = os.path.join(ROOT, 'tests', 'fixtures', 'vyos-pi.config.boot.default')
EXAMPLE = os.path.join(ROOT, 'examples', 'home-router.config.boot')
EXAMPLE_NOTES = os.path.join(ROOT, 'examples', 'home-router.notes.txt')
# the arguments examples/home-router.config.boot was made with (see examples/README.md)
EXAMPLE_ARGS = ['--if', 'wan=eth0', '--if', 'lan=eth1=02:00:00:00:aa:01',
                '--if', 'opt1=eth2=02:00:00:00:aa:02']

spec = importlib.util.spec_from_file_location('opnsense_to_vyos', SCRIPT)
conv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conv)


def run(*extra, sample=SAMPLE, default=DEFAULT):
    with tempfile.TemporaryDirectory() as d:
        out, notes = os.path.join(d, 'out'), os.path.join(d, 'notes')
        conv.main([sample, default, out, '--notes', notes, *extra])
        with open(out) as f, open(notes) as g:
            return f.read(), g.read()


def rules(chain):
    """[(number, rule node)] of a filter chain, in number order."""
    return sorted(((int(k.split()[1]), v) for k, v in chain.items() if k.startswith('rule ')))


def find(chain, description):
    hits = [(n, r) for n, r in rules(chain) if r.get('description') == [description]]
    return hits[0] if hits else (None, None)


class SampleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text, cls.notes = run(*EXAMPLE_ARGS)
        cls.cfg, cls.footer = conv.parse_boot(cls.text)
        fw = cls.cfg['firewall']
        cls.fwd = fw['ipv4']['forward']['filter']
        cls.inp = fw['ipv4']['input']['filter']

    def test_example_is_up_to_date(self):
        with open(EXAMPLE) as f:
            self.assertEqual(self.text, f.read(), 'regenerate examples/home-router.config.boot')
        with open(EXAMPLE_NOTES) as f:
            self.assertEqual(self.notes, f.read(), 'regenerate examples/home-router.notes.txt')

    def test_braces_balance(self):
        self.assertEqual(self.text.count('{'), self.text.count('}'))

    def test_footer_pins_nic_names(self):
        self.assertIn('vyos-config-version', self.footer)
        self.assertIn('interfaces@34', self.footer)

    def test_interfaces(self):
        eth = self.cfg['interfaces']
        self.assertEqual(eth['ethernet eth0']['address'], ['dhcp', 'dhcpv6'])
        self.assertEqual(eth['ethernet eth1']['hw-id'], ['02:00:00:00:aa:01'])
        self.assertEqual(eth['ethernet eth1']['address'], ['10.20.0.1/24'])
        self.assertEqual(eth['ethernet eth1']['vif 30']['address'], ['10.20.30.1/24'])
        pd = eth['ethernet eth0']['dhcpv6-options']['pd 0']
        self.assertEqual(pd['length'], ['56'])
        self.assertIn('interface eth1', pd)
        self.assertIn('interface eth1', self.cfg['service']['router-advert'])

    def test_wireguard(self):
        wg = self.cfg['interfaces']['wireguard wg0']
        self.assertEqual(wg['address'], ['10.99.0.1/24'])
        self.assertEqual(wg['port'], ['51820'])
        self.assertEqual(wg['peer laptop']['allowed-ips'], ['10.99.0.3/32'])
        self.assertIn('preshared-key', wg['peer laptop'])
        self.assertEqual(wg['peer phone']['persistent-keepalive'], ['25'])

    def test_alias_groups(self):
        g = self.cfg['firewall']['group']
        self.assertEqual(g['address-group WebServer']['address'], ['10.20.0.50'])
        self.assertEqual(g['network-group BlockedNets']['network'], ['198.51.100.0/24', '203.0.113.0/25'])
        self.assertEqual(g['remote-group SpamhausDROP']['url'], ['https://www.spamhaus.org/drop/drop.txt'])
        self.assertEqual(g['remote-group SpamhausDROP']['interval'], ['86400'])
        self.assertEqual(g['remote-group FeodoTracker']['interval'], ['43200'])
        self.assertEqual(g['mac-group TrustedIoT']['mac-address'], ['02:00:00:00:10:01', '02:00:00:00:10:02'])
        self.assertEqual(g['port-group CastPorts']['port'], ['8008-8009', '8443'])
        self.assertEqual(g['interface-group LAN_IOT']['interface'], ['eth1', 'eth2'])
        self.assertNotIn('remote-group GeoIP_Blocked', g)

    def test_rule_order_follows_sequence(self):
        spam, _ = find(self.fwd, 'Block outbound to Spamhaus DROP')
        feodo, _ = find(self.fwd, 'Block outbound to Feodo C2')
        nets, _ = find(self.fwd, 'Block outbound to BlockedNets')
        trusted, _ = find(self.fwd, 'Trusted IoT to the LAN (cast ports)')
        iot_block, _ = find(self.fwd, 'IoT: nothing else to the LAN')
        legacy, _ = find(self.fwd, 'Default allow LAN to any rule')
        self.assertTrue(spam < feodo < nets < trusted < iot_block < legacy)

    def test_rule_contents(self):
        _, r = find(self.fwd, 'Block outbound to Spamhaus DROP')
        self.assertEqual(r['action'], ['drop'])
        self.assertEqual(r['inbound-interface']['group'], ['LAN_IOT'])
        self.assertEqual(r['destination']['group']['remote-group'], ['SpamhausDROP'])
        self.assertIn('log', r)
        _, r = find(self.fwd, 'Trusted IoT to the LAN (cast ports)')
        self.assertEqual(r['source']['group']['mac-group'], ['TrustedIoT'])
        self.assertEqual(r['destination']['group']['port-group'], ['CastPorts'])
        self.assertEqual(r['destination']['address'], ['10.20.0.0/24'])
        self.assertEqual(r['protocol'], ['tcp'])
        _, r = find(self.fwd, 'Printers: nothing but the LAN')
        self.assertEqual(r['destination']['address'], ['!10.20.0.0/24'])
        self.assertEqual(r['source']['group']['address-group'], ['Printers'])

    def test_chains(self):
        # destination (self) / wanip: input only
        self.assertEqual(find(self.fwd, 'IoT: DNS to the router'), (None, None))
        n, r = find(self.inp, 'IoT: DNS to the router')
        self.assertEqual(r['protocol'], ['tcp_udp'])
        self.assertNotIn('address', r.get('destination', {}))
        self.assertEqual(find(self.fwd, 'WireGuard in'), (None, None))
        self.assertIsNotNone(find(self.inp, 'WireGuard in')[0])
        # a destination network holding a router address: both chains
        self.assertIsNotNone(find(self.fwd, 'Guests: internet only')[0])
        self.assertIsNotNone(find(self.inp, 'Guests: internet only')[0])
        # a remote list: forward only
        self.assertEqual(find(self.inp, 'Block outbound to Spamhaus DROP'), (None, None))

    def test_disabled_things_stay_disabled(self):
        _, r = find(self.inp, 'Old VPN peers (alias disabled)')
        self.assertIn('disable', r)
        _, r = find(self.fwd, 'old SSH forward (off)')
        self.assertIn('disable', r)
        _, r = find(self.fwd, 'Policy route via a backup uplink (off)')
        self.assertIn('disable', r)

    def test_implicit_rules(self):
        self.assertIsNotNone(find(self.fwd, 'port forwards (nat destination)')[0])
        _, r = find(self.inp, 'DHCP server on opt2')
        self.assertEqual(r['inbound-interface']['name'], ['eth1.30'])
        _, r = find(self.inp, 'Block bogon networks on wan')
        self.assertEqual(r['source']['group']['network-group'], ['OPN-BOGONS'])
        self.assertIsNotNone(find(self.inp, 'anti-lockout: SSH from lan')[0])

    def test_nat(self):
        dst = self.cfg['nat']['destination']
        self.assertEqual(dst['rule 10']['translation']['address'], ['10.20.0.50'])
        self.assertEqual(dst['rule 10']['destination']['port'], ['443'])
        self.assertNotIn('disable', dst['rule 10'])
        self.assertIn('disable', dst['rule 20'])
        src = self.cfg['nat']['source']
        self.assertEqual(src['rule 10']['source']['address'], ['10.99.0.0/24'])
        auto = sorted(r['source']['address'][0] for k, r in src.items() if k != 'rule 10')
        self.assertEqual(auto, ['10.20.0.0/24', '10.20.1.0/24', '10.20.30.0/24', '10.99.0.0/24'])

    def test_dhcp(self):
        srv = self.cfg['service']['dhcp-server']
        lan = srv['shared-network-name LAN']['subnet 10.20.0.0/24']
        self.assertEqual(lan['range 0']['start'], ['10.20.0.100'])
        self.assertEqual(lan['option']['domain-name'], ['home.example'])
        self.assertEqual(lan['static-mapping nas']['mac'], ['02:00:00:00:00:51'])
        self.assertNotIn('static-mapping nas-wifi', lan)
        self.assertIn('shared-network-name GUEST', srv)
        self.assertIn('hostfile-update', srv)
        self.assertIn('repeats an IP or MAC', self.notes)

    def test_dns(self):
        fwd = self.cfg['service']['dns']['forwarding']
        self.assertEqual(fwd['dnssec'], ['validate'])
        self.assertEqual(fwd['domain corp.example']['name-server'], ['192.0.2.53'])
        self.assertIn('10.99.0.0/24', fwd['allow-from'])
        self.assertEqual(self.cfg['system']['static-host-mapping']['host-name nas.home.example']['inet'],
                         ['10.20.0.51'])

    def test_system(self):
        s = self.cfg['system']
        self.assertEqual(s['host-name'], ['router'])
        self.assertEqual(s['time-zone'], ['America/Chicago'])
        keys = s['login']['user vyos']['authentication']
        self.assertIn('public-keys admin-example.net', keys)
        self.assertIn('disable-password-authentication', self.cfg['service']['ssh'])
        self.assertIn('server 0.pool.ntp.org', self.cfg['service']['ntp'])
        self.assertNotIn('server time1.vyos.net', self.cfg['service']['ntp'])
        nf = s['flow-accounting']['netflow']
        self.assertEqual(nf['server 192.0.2.50']['port'], ['2055'])
        self.assertEqual(nf['interface'], ['eth1', 'eth0'])

    def test_ids(self):
        s = self.cfg['service']['suricata']
        self.assertEqual(s['interface'], ['eth0'])
        self.assertEqual(s['address-group home-net']['address'], ['10.20.0.0/16', '10.99.0.0/24'])
        self.assertEqual(s['address-group external-net']['group'], ['!home-net'])
        self.assertEqual(s['port-group shellcode-ports']['group'], ['!http-ports'])
        self.assertEqual(s['log']['eve']['type'], ['alert', 'tls'])
        task = self.cfg['system']['task-scheduler']['task suricata-update']
        self.assertEqual(task['executable']['path'], ['/usr/libexec/vyos/op_mode/update_suricata.sh'])
        self.assertIn('update suricata', self.notes)

    def test_gaps_are_noted(self):
        for gap in ('Suricata', 'traffic shaper', 'monit', 'DNS blocklists', 'GeoIP', 'NAT reflection',
                    'policy routing'):
            self.assertIn(gap, self.notes)


def run_xml(edit, *extra):
    """run() on a copy of the sample with edit(xml_text) -> xml_text applied."""
    with open(SAMPLE) as f:
        xml = edit(f.read())
    with tempfile.NamedTemporaryFile('w', suffix='.xml', delete=False) as f:
        f.write(xml)
    try:
        text, notes = run(*(extra or EXAMPLE_ARGS), sample=f.name)
    finally:
        os.unlink(f.name)
    return conv.parse_boot(text)[0], notes


class ParityTest(unittest.TestCase):
    """Behaviour that must match what pf on OPNsense actually does."""

    @classmethod
    def setUpClass(cls):
        cls.text, cls.notes = run(*EXAMPLE_ARGS)
        cls.cfg, _ = conv.parse_boot(cls.text)

    def test_multi_interface_rules_precede_single_interface_ones(self):
        # pf: rules on several interfaces are "floating" (priority 200000) and come
        # before single-interface rules (400000) whatever their sequence numbers
        cfg, _ = run_xml(lambda x: x.replace(
            '<sequence>10</sequence>\n            <action>block</action>\n            <quick>1</quick>\n'
            '            <interface>lan,opt1</interface>',
            '<sequence>90</sequence>\n            <action>block</action>\n            <quick>1</quick>\n'
            '            <interface>lan,opt1</interface>'))
        fwd = cfg['firewall']['ipv4']['forward']['filter']
        spam, _ = find(fwd, 'Block outbound to Spamhaus DROP')
        trusted, _ = find(fwd, 'Trusted IoT to the LAN (cast ports)')
        guests, _ = find(fwd, 'Guests: internet only')
        self.assertTrue(spam < trusted and spam < guests)

    def test_interface_group_rules_between_floating_and_interfaces(self):
        fwd = self.cfg['firewall']['ipv4']['forward']['filter']
        feodo, _ = find(fwd, 'Block outbound to Feodo C2')
        wg, _ = find(fwd, 'WireGuard clients to anywhere')
        trusted, _ = find(fwd, 'Trusted IoT to the LAN (cast ports)')
        self.assertTrue(feodo < wg < trusted)

    def test_natural_uuid_order(self):
        key = conv.Converter._natural
        self.assertLess(key('6e8e67d8'), key('12e06f06'))
        self.assertLess(key('12e06f06'), key('d83c9860'))

    def test_icmpv6_like_pf(self):
        fwd = self.cfg['firewall']['ipv6']['forward']['filter']
        types = sorted(r['icmpv6']['type-name'][0] for _, r in rules(fwd) if 'icmpv6' in r)
        self.assertEqual(types, sorted(conv.Converter.ICMP6_ERRORS))
        inp = self.cfg['firewall']['ipv6']['input']['filter']
        _, echo = find(inp, 'ICMPv6 echo-request from link-local')
        self.assertEqual(echo['source']['address'], ['fe80::/10'])

    def test_dhcp6_wan_accepts_router_advertisements(self):
        wan = self.cfg['interfaces']['ethernet eth0']
        self.assertIn('autoconf', wan['ipv6']['address'])

    def test_tracking_interface_ra_like_opnsense(self):
        ra = self.cfg['service']['router-advert']['interface eth1']
        self.assertIn('managed-flag', ra)
        self.assertIn('other-config-flag', ra)
        self.assertEqual(ra['dnssl'], ['home.example'])

    def test_ra_off_when_radvd_entry_disabled(self):
        cfg, notes = run_xml(lambda x: x.replace(
            '<OPNsense>', '<OPNsense><radvd><entries><entry uuid="r1"><enabled>0</enabled>'
            '<interface>lan</interface></entry></entries></radvd>', 1))
        self.assertNotIn('router-advert', cfg.get('service', {}))
        self.assertIn('router advertisements are off', notes)

    def test_dhcp_defaults_of_dhcpd(self):
        srv = self.cfg['service']['dhcp-server']
        for net in srv.values():
            if not isinstance(net, dict):
                continue
            for k, sub in net.items():
                if k.startswith('subnet '):
                    self.assertIn('domain-name', sub['option'])
                    self.assertTrue(sub['lease'])

    def test_reservations_and_router_name_in_dns(self):
        hosts = self.cfg['system']['static-host-mapping']
        self.assertEqual(hosts['host-name nas.home.example']['inet'], ['10.20.0.51'])
        self.assertIn('10.20.0.1', hosts['host-name router.home.example']['inet'])

    def test_dns_listens_on_wireguard(self):
        fwd = self.cfg['service']['dns']['forwarding']
        self.assertIn('10.99.0.1', fwd['listen-address'])

    def test_system_resolver_from_wan_dhcp(self):
        cfg, _ = run_xml(lambda x: x.replace('<hostname>router</hostname>',
                                             '<hostname>router</hostname><dnsallowoverride>1</dnsallowoverride>'))
        self.assertEqual(cfg['system']['name-server'], ['eth0'])

    def test_ntp_pool(self):
        self.assertIn('pool', self.cfg['service']['ntp']['server 0.pool.ntp.org'])

    def test_netflow_to_localhost_left_out(self):
        cfg, notes = run_xml(lambda x: x.replace('<targets>192.0.2.50:2055</targets>',
                                                 '<targets>127.0.0.1:2056</targets>'))
        self.assertNotIn('flow-accounting', cfg['system'])
        self.assertIn('left out', notes)

    def test_not_any_note_says_what_pf_does(self):
        cfg, notes = run_xml(lambda x: x.replace(
            '<destination_net>SpamhausDROP</destination_net>',
            '<destination_net>any</destination_net><destination_not>1</destination_not>'))
        _, r = find(cfg['firewall']['ipv4']['forward']['filter'], 'Block outbound to Spamhaus DROP')
        self.assertIn('disable', r)
        self.assertIn('pf matches every address', notes)


class ErrorTest(unittest.TestCase):
    def test_unmapped_interface(self):
        with self.assertRaises(SystemExit) as e:
            run('--if', 'wan=eth0', '--if', 'lan=eth1')
        self.assertIn('opt1', str(e.exception))

    def test_bad_mac(self):
        with self.assertRaises(SystemExit):
            run('--if', 'wan=eth0=nope', '--if', 'lan=eth1', '--if', 'opt1=eth2')

    def test_default_needs_footer(self):
        with tempfile.NamedTemporaryFile('w', suffix='.boot', delete=False) as f:
            f.write('system {\n}\n')
        try:
            with self.assertRaises(SystemExit):
                run(*EXAMPLE_ARGS, default=f.name)
        finally:
            os.unlink(f.name)

    def test_without_macs_no_pinning(self):
        text, _ = run('--if', 'wan=eth0', '--if', 'lan=eth1', '--if', 'opt1=eth2')
        self.assertNotIn('hw-id', text)
        self.assertIn('interfaces@35', text)


if __name__ == '__main__':
    with contextlib.redirect_stderr(io.StringIO()):
        unittest.main()
