# Example: a home router like opnsense-pi

[`home-router.config.boot`](home-router.config.boot) is a complete VyOS
configuration for a Raspberry Pi 5 home router shaped like an
[opnsense-pi](https://github.com/itpick/opnsense-pi) install: the onboard port
is the WAN, two USB NICs are the LAN and an IoT network, and a guest VLAN
rides on the LAN. It was made by
[`scripts/opnsense-to-vyos.py`](../scripts/opnsense-to-vyos.py) from
[`opnsense-sample.config.xml`](opnsense-sample.config.xml), a made-up OPNsense
26.7 config; the translator's notes are in
[`home-router.notes.txt`](home-router.notes.txt). Every address, MAC and key
in these files is fake.

```sh
scripts/opnsense-to-vyos.py examples/opnsense-sample.config.xml \
  tests/fixtures/vyos-pi.config.boot.default examples/home-router.config.boot \
  --if wan=eth0 --if lan=eth1=02:00:00:00:aa:01 --if opt1=eth2=02:00:00:00:aa:02 \
  --notes examples/home-router.notes.txt
```

For your own router: download `config.xml` (System > Configuration > Backups,
or `GET /api/core/backup/download/this`), map each OPNsense interface to a
VyOS NIC (`--if KEY=ethN=MAC`: the Pi 5's onboard port is `eth0`; give the USB
NICs' MACs so their names stay put), add `--ssh-key`, read the notes, and put
the result on the image's FAT partition as `vyos-pi/config.boot` (see
[First-boot settings](../README.md#first-boot-settings)). Use the default
config of the image you flash (`vyos-pi/config.boot.default` on its FAT
partition) as the second argument, so the version footer matches. The output
holds your keys: keep it out of git.

Test it the way you would any router change: on a spare Pi, with a client on
its LAN side, before it replaces the working one.

## OPNsense to VyOS

| OPNsense | VyOS | Translated |
|---|---|---|
| Interfaces: assignments, static IPv4, DHCP WAN | `interfaces ethernet ethN address` (`dhcp`) | yes |
| VLANs | `interfaces ethernet ethN vif TAG` | yes |
| IPv6: DHCPv6 WAN, track interface (prefix delegation) | `address dhcpv6` + `ipv6 address autoconf` (default route from the uplink's RAs, as OPNsense does), `dhcpv6-options pd 0 interface …`, `service router-advert` with OPNsense's automatic flags (managed, other-config, DNSSL) | yes (no RDNSS: the tracked address is not known in advance) |
| Block private / bogon networks on WAN | `network-group` + drop rules first on the WAN | yes |
| Aliases: host, network | `firewall group address-group` / `network-group` (and `ipv6-…`) | yes |
| Aliases: port | `firewall group port-group` | yes |
| Aliases: MAC | `firewall group mac-group` | yes |
| Aliases: URL table (IPs) | `firewall group remote-group` (VyOS downloads the list on `interval`) | yes |
| Aliases: GeoIP | `source/destination geoip country-code` | no: noted |
| Firewall rules, in pf's order: floating and multi-interface rules, then interface groups, then single interfaces; within each, Rules [new] by sequence (then uuid), then the legacy rules | `firewall ipv4/ipv6 forward filter` and `input filter`, first match | yes |
| Rule "destination: This Firewall" / interface address | the `input` chain | yes |
| Port forwards | `nat destination rule`, plus one `forward` rule accepting `connection-status nat destination` | yes |
| NAT reflection | extra destination + source rules, or split DNS | no: noted |
| Outbound NAT: automatic / hybrid / manual | `nat source rule … translation address masquerade` | yes |
| Kea DHCPv4 or ISC dhcpd (whichever is on) | `service dhcp-server` (Kea): subnets, ranges, options, static mappings | yes |
| Unbound (resolver) | `service dns forwarding` (PowerDNS recursor), recursive without `name-server` | yes |
| Unbound query forwarding (per domain or all) | `domain X name-server Y` / `name-server` / `system` | yes (DNS over TLS forwards as plain DNS) |
| Unbound host overrides | `system static-host-mapping` | yes (A/AAAA) |
| Register DHCP leases / reservations / the firewall's own name in DNS | `service dhcp-server hostfile-update` / `system static-host-mapping` | yes |
| Unbound DNSBL (blocklists) | none | no: noted |
| WireGuard instances and peers | `interfaces wireguard wgN` with `peer` | yes |
| NetFlow export | `system flow-accounting netflow` | yes (OPNsense's local Insight collector on 127.0.0.1 has no VyOS equivalent and is left out) |
| Remote syslog | `system syslog remote` | yes |
| NTP servers | `service ntp server` | yes |
| SSH, root's authorized keys | `service ssh`, user `vyos` public keys | yes |
| Policy routing (gateway on a rule) | `policy route` | no: noted |
| Traffic shaper | `qos policy shaper` / `fq-codel` / `cake` | no: noted |
| Monit | `service monitoring` (Prometheus exporters, Telegraf) | no: noted |
| Intrusion detection (Suricata) | `service suricata` (IDS: alerts only), rules from `update suricata` (a daily `task-scheduler` job) | yes: interfaces, HOME_NET, EVE log types; not OPNsense's ruleset/policy choices, not IPS |
| OpenVPN, IPsec, captive portal | `interfaces openvpn`, `vpn ipsec`, none | no: noted |

## Gaps

- **IPS and rule management.** VyOS rolling ships Suricata 7
  (`service suricata`), but as an IDS only: it listens with af-packet and
  logs alerts, with no inline (IPS) mode and no blocking. Its rules come from
  `suricata-update` (ET Open unless you add sources), so OPNsense's per-ruleset
  and policy choices (which categories to drop or alert) do not carry over.
  Run `update suricata` once after the first commit. Suricata wants several
  hundred MB of RAM with ET Open: fine on a 4 or 8 GB Pi 5, tight on 2 GB.
- **DNS blocklists.** The PowerDNS recursor in VyOS has no blocklist feature.
  Run a blocker (AdGuard Home, Pi-hole) and hand it out by DHCP, or forward to
  a filtering resolver.
- **Flow reporting.** VyOS exports NetFlow but keeps no local database or
  dashboard: point it at nfcapd, ntopng or Akvorado.
- **GeoIP aliases.** VyOS matches countries itself (`geoip country-code`); the
  converter leaves those rules out instead of guessing. URL-table aliases
  that point at country lists (IPdeny zones) do translate, as remote-groups.
- **Rule semantics.** pf's non-quick (last-match) rules and floating rules are
  not translated one to one; the notes name each one. Rules are otherwise
  kept in OPNsense's evaluation order, including rules that a broader rule
  above them already decides (the converter does not reorder them).
