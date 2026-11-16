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
