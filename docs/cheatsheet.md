# VyOS cheat sheet for OPNsense users

VyOS has no web UI. This page lists the CLI equivalents of the things you would click in the
OPNsense GUI on a home router. The commands were checked on a Pi 5 running vyos-pi 2026.11.16-2
(VyOS rolling, November 2026) and against the [VyOS documentation](https://docs.vyos.io/en/latest/).

The examples use documentation addresses. Substitute your own:

| | Example |
|---|---|
| WAN | `eth0`, DHCP from the ISP; public address 203.0.113.10 |
| LAN | `eth1`, 192.0.2.1/24, DHCP pool (shared-network-name) `LAN` |
| Second LAN (Wi-Fi) | `eth2`, 198.51.100.1/24, pool `WIFI` |
| WireGuard | `wg0`, 10.0.99.1/24, UDP 51820 |
| MACs | 00:00:5e:00:53:xx ([RFC 7042](https://www.rfc-editor.org/rfc/rfc7042) documentation range) |

A router converted with [`opnsense-to-vyos.py`](../scripts/opnsense-to-vyos.py) uses this layout:
OPNsense rules become numbered rules in `firewall ipv4 forward filter` and `input filter`,
aliases become firewall groups, and DHCP ranges become pools named after the OPNsense interfaces.
Run `show configuration commands` to see your router's actual names.

## Basics

```sh
ssh vyos@192.0.2.1
```
If SSH is unreachable, log in on the console. On a Pi 5 that is the debug UART at 115200 baud.

VyOS has two modes. **Operational mode** (`$` prompt) is for `show`, `monitor`, `reset` and
`reboot`. **Configuration mode** (`#` prompt) is for `set` and `delete`, and changes take effect
only when you commit them.

```
configure                     # enter configuration mode
set ... / delete ...          # edit the candidate config (nothing takes effect yet)
compare                       # diff the candidate against the running config ("compare saved": against the saved config)
commit                        # apply
commit-confirm 5              # apply; revert after 5 min unless you type "confirm" (default 10)
confirm                       # keep a commit-confirm'd change
save                          # write /config/config.boot, so the change survives a reboot
exit                          # leave (refused while there are uncommitted changes)
exit discard                  # leave and throw the candidate away
discard                       # throw the candidate away and stay in configuration mode
run show ...                  # run any operational command from configuration mode
```

**`commit-confirm` is the safety net for remote changes.** Use it for anything that could cut
off your session: input firewall rules, interface addresses, the SSH service. It commits and
starts a timer. If you do not type `confirm` before the timer runs out, VyOS restores the
configuration from before that commit. It does this without a reboot, because the default
action is `reload`; set `system config-management commit-confirm action reboot` to make it
reboot instead. A commit is lost at reboot until you `save` it.

Viewing the configuration:
```
show configuration commands                       # the whole config as set commands
show configuration commands | match dhcp-server   # filter it (also: | no-match, | count)
show configuration commands | strip-private       # mask keys and public addresses before you share it
run show configuration commands | grep wg0        # the same, from configuration mode
```

Config history (VyOS keeps `system config-management commit-revisions` revisions):
```
show system commit             # numbered list of commits; 0 is the current one
show system commit diff 1      # what commit 1 changed
compare 1                      # (configuration mode) diff the candidate against revision 1
rollback-soft 1                # (configuration mode) load revision 1 into the candidate; compare, then commit
rollback 1                     # (configuration mode) reboot into revision 1 (it asks first)
```

## DHCP

VyOS's DHCP server is Kea.
```
show dhcp server leases                    # all leases; add "pool LAN" or "sort ip" to narrow or sort
show dhcp server leases state active
show dhcp server static-mappings           # reservations
show dhcp server statistics                # pool sizes and usage
show log dhcp server
```

To add a static reservation:
```
configure
set service dhcp-server shared-network-name LAN subnet 192.0.2.0/24 static-mapping nas mac '00:00:5e:00:53:01'
set service dhcp-server shared-network-name LAN subnet 192.0.2.0/24 static-mapping nas ip-address '192.0.2.20'
set service dhcp-server shared-network-name LAN subnet 192.0.2.0/24 static-mapping nas description 'NAS'
set system static-host-mapping host-name nas.lan inet '192.0.2.20'      # optional: a DNS name for it
commit; save; exit
```
The device gets the reserved address when it next renews its lease, or when you reconnect it.

To remove the reservation and its DNS name:
```
delete service dhcp-server shared-network-name LAN subnet 192.0.2.0/24 static-mapping nas
delete system static-host-mapping host-name nas.lan
```

To change a pool's range:
```
set service dhcp-server shared-network-name LAN subnet 192.0.2.0/24 range 0 start '192.0.2.100'
set service dhcp-server shared-network-name LAN subnet 192.0.2.0/24 range 0 stop  '192.0.2.199'
```
Other settings under the subnet: `lease`, `option name-server`, `option default-router`, `option domain-name`.

## DNS

VyOS's DNS service (`service dns forwarding`) is the PowerDNS recursor.

**Host overrides** (OPNsense: Unbound → Host Overrides):
```
set system static-host-mapping host-name printer.lan inet '198.51.100.20'
set system static-host-mapping host-name printer.lan alias 'hp.lan'
```
The recursor answers with these names. With `service dhcp-server hostfile-update` set, it also
answers with the hostnames of DHCP clients.

**Flush the cache:**
```
reset dns forwarding all                   # the whole cache; "reset dns forwarding domain example.com" for one name
show dns forwarding statistics
```

**AdGuard Home** (only if you run it, for example as a `container`). Its web UI is on port 3000 by
default, for example http://192.0.2.1:3000.
- To allowlist a domain, open **Query Log**, find the blocked query and click **Unblock**. Or add
  `@@||example.com^` under **Filters → Custom filtering rules**. To block a domain, add `||example.com^` there.
- To flush its cache, use **Settings → DNS settings → Clear cache**, or call `POST /control/cache_clear`.
- It caches separately from the recursor, so after you change a host override, flush both caches.

## Firewall

VyOS firewall chains:
- `firewall ipv4 forward filter` handles traffic **through** the router. These are OPNsense's per-interface rules.
- `firewall ipv4 input filter` handles traffic **to** the router itself: SSH, DNS, DHCP and WireGuard.
- `ipv6 forward filter` and `ipv6 input filter` do the same for IPv6.
- The usual setup is `default-action drop` on each chain, with
  `firewall global-options state-policy established action accept` (and `related`) for return traffic.
- Rules run in number order and the first match wins. A chain covers **all** interfaces, so each
  rule names its interface with `inbound-interface name eth1` or `inbound-interface group <name>`.

Viewing rules:
```
show firewall                                  # every chain, with packet and byte counters per rule
show firewall ipv4 forward filter
show firewall ipv4 forward filter rule 150
show firewall statistics
show firewall group                            # groups, their members, and the rules that use them
```

**Block a LAN device from the internet.** Give the rule a lower number than your "LAN to any"
accept rule, so it matches first:
```
configure
set firewall ipv4 forward filter rule 145 action 'drop'
set firewall ipv4 forward filter rule 145 description 'TV: no internet'
set firewall ipv4 forward filter rule 145 inbound-interface name 'eth1'
set firewall ipv4 forward filter rule 145 outbound-interface name 'eth0'
set firewall ipv4 forward filter rule 145 source address '192.0.2.50'
set firewall ipv4 forward filter rule 145 log
commit; save; exit
```

**Allow a service on the router from the Wi-Fi LAN.** This goes in the input chain, so use
`commit-confirm`:
```
set firewall ipv4 input filter rule 175 action 'accept'
set firewall ipv4 input filter rule 175 inbound-interface name 'eth2'
set firewall ipv4 input filter rule 175 protocol 'udp'
set firewall ipv4 input filter rule 175 destination port '123'
```

Rule housekeeping:
- `set ... rule 145 disable` turns a rule off and keeps it.
- `delete firewall ipv4 forward filter rule 145` removes it.
- To renumber a rule, run `edit firewall ipv4 forward filter`, then `rename rule 145 to rule 146` (or `copy`), then `top`.

**Logs** show only the rules that have `log` set. The log prefix encodes the chain, the rule
number and the action: `[ipv4-FWD-filter-145-D]` means rule 145 of the forward chain dropped it.
```
show log firewall
show log firewall ipv4 forward filter
show log firewall ipv4 forward filter rule 145
sudo journalctl -kf | grep 'ipv4-'           # follow the log live
```

**Aliases become firewall groups.** Define a group with `set firewall group <type> <name> ...`,
then use it in a rule with `source group <type> <name>` or `destination group <type> <name>`.

| OPNsense alias | VyOS group |
|---|---|
| Host(s) | `address-group` (`address 192.0.2.20`, or a range) |
| Network(s) | `network-group` (`network 192.0.2.0/24`) |
| Port(s) | `port-group` (`port 443`, `port 8000-8100`) |
| URL Table (IPs) | `remote-group` (`url https://...`, `interval` in seconds) |
| MAC address | `mac-group` |
| Interface group | `interface-group` |
| Host name (FQDN) | `domain-group` |

```
set firewall group port-group Web port '80'
set firewall group port-group Web port '443'
set firewall ipv4 forward filter rule 145 protocol 'tcp'
set firewall ipv4 forward filter rule 145 destination group port-group 'Web'
```

## NAT

**Port forwards** are `nat destination` rules. The forwarded traffic also needs a forward-chain
accept rule. One rule covers every forward:
```
set firewall ipv4 forward filter rule 30 action 'accept'
set firewall ipv4 forward filter rule 30 connection-status nat 'destination'
```
To add a port forward:
```
set nat destination rule 10 description 'web server'
set nat destination rule 10 inbound-interface name 'eth0'
set nat destination rule 10 protocol 'tcp'
set nat destination rule 10 destination port '443'
set nat destination rule 10 translation address '192.0.2.30'
set nat destination rule 10 translation port '443'
```
`set nat destination rule 10 disable` turns it off and keeps it, and `delete nat destination rule 10 disable` turns it back on.
```
show nat destination rules                 # lists only the enabled rules
show nat destination statistics
show configuration commands | match 'nat destination'   # every rule, including the disabled ones
```

**Outbound NAT** is `nat source`. Each LAN subnet is masqueraded out the WAN:
```
set nat source rule 100 outbound-interface name 'eth0'
set nat source rule 100 source address '192.0.2.0/24'
set nat source rule 100 translation address 'masquerade'
show nat source rules
show nat source statistics
```

## WireGuard

```
show interfaces wireguard wg0 summary      # peers, latest handshake, endpoint, transfer
show interfaces wireguard wg0 endpoints
show interfaces wireguard wg0              # interface counters
```
A peer with a `latest handshake` under about 2 minutes is connected. The server's private key is
in the config, so mask it with `| strip-private` before you share any config output.

**Add a peer.** Make the key pair on the client or on your workstation, so the client's private
key is never on the router:
```sh
wg genkey | tee phone.key | wg pubkey > phone.pub
```
```
configure
set interfaces wireguard wg0 peer phone public-key '<contents of phone.pub>'
set interfaces wireguard wg0 peer phone allowed-ips '10.0.99.2/32'
set interfaces wireguard wg0 peer phone persistent-keepalive '25'
commit; save; exit
```
The firewall needs two rules for WireGuard. The input chain must accept UDP 51820 on `eth0`, and
the forward chain must accept traffic from `wg0` to wherever its peers may go.

**Client config:**
```ini
[Interface]
PrivateKey = <contents of phone.key>
Address = 10.0.99.2/32
DNS = 10.0.99.1

[Peer]
PublicKey = <the "public key" line of: show interfaces wireguard wg0 summary>
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```
- For a split tunnel, list only your networks in `AllowedIPs` (here: `192.0.2.0/24, 198.51.100.0/24, 10.0.99.0/24`).
- To import the config on a phone, show it as a QR code: `qrencode -t ansiutf8 < phone.conf`.
- With `DNS = 10.0.99.1`, the router's DNS service needs `allow-from` and `listen-address` entries for the tunnel.

VyOS can also generate the client config itself:
```
generate wireguard client-config phone interface wg0 server 203.0.113.10 address 10.0.99.2
```
It prints the `set` commands for the peer, a client config and a QR code. It creates the key pair
on the router, and its config uses `DNS = 1.1.1.1`, which you may want to change.

To remove a peer: `delete interfaces wireguard wg0 peer phone`.

## Interfaces

```
show interfaces                            # addresses, MACs, state, descriptions
show interfaces counters                   # packets, bytes, drops and errors per interface
show interfaces ethernet eth0              # details and counters for one interface
show interfaces ethernet eth1 physical     # ethtool output: "Speed:", duplex, link modes
```
**USB NICs are named by USB port, not by MAC.** VyOS keeps the mapping in
`/config/interface-mapping.json`, and a USB NIC's slot is the port it is plugged into. If you
swap two USB adapters between ports, their interface names swap too, and so do your LAN
configurations. Leave each adapter in its port. If an adapter has to move, check the MAC for each
name in `show interfaces` before you reconnect the cables.

## Monitoring

```
show system uptime                         # includes load averages
show hardware cpu summary
top    /    htop                           # CPU by process
show system memory
show system storage
show environment sensors                   # SoC temperature (and NVMe, if fitted)
show conntrack table ipv4                  # the state table (OPNsense: Diagnostics → States)
show conntrack statistics
cat /proc/sys/net/netfilter/nf_conntrack_count
monitor traffic interface eth0 filter 'udp port 51820'   # tcpdump; options: verbose, numeric, save <file>
monitor bandwidth interface eth0
monitor log
show log tail
```
On vyos-pi 2026.11.16-2, `show system cpu` prints nothing (the Pi's CPU model reads as
"unknown"). Use `show hardware cpu summary` and `top` instead.

**Suricata** (`service suricata`; see the [README](../README.md#ids-and-ips-suricata)):
```
sudo tail -f /var/log/suricata/eve.json | jq -c '{t:.timestamp,src:.src_ip,dst:.dest_ip,sig:.alert.signature}'
update suricata                            # fetch the rules and restart Suricata
restart suricata
sudo /usr/libexec/vyos-pi/vyos-pi-suricata-mode ips          # IPS on all forwarded traffic; fails open
sudo /usr/libexec/vyos-pi/vyos-pi-suricata-mode ips closed   # IPS; drops traffic while Suricata is down
sudo /usr/libexec/vyos-pi/vyos-pi-suricata-mode ids          # back to VyOS's af-packet IDS
```
The mode is stored in `/config/vyos-pi/suricata.conf`. If the file is missing, Suricata runs as an IDS.

**ntopng** (OPNsense: Reporting → Insight / NetFlow). If you run it as a container, its UI is at
http://192.0.2.1:&lt;port&gt; (ntopng's default port is 3000). Container commands:
`show container`, `restart container ntopng`, `show log container ntopng`.

## System

```
reboot                                     # also: reboot in 10, reboot at 03:00, reboot cancel
poweroff                                   # also: poweroff in <minutes>, poweroff at <time>, poweroff cancel
show version
show system image                          # installed images, which is the default, which is running
add system image https://github.com/itpick/vyos-pi/releases/download/<tag>/vyos-pi-arm64.iso
set system image default-boot <name>       # operational mode: choose the image for the next boot
delete system image <name>
```
`add system image` keeps your configuration and asks whether the new image should be the default.
Reboot to start it. Earlier images stay installed, so you can boot back into one with
`set system image default-boot`. Releases are listed at https://github.com/itpick/vyos-pi/releases.

## Going back to OPNsense

The safest way to switch is to leave the old OPNsense box unchanged and only move cables. If
VyOS misbehaves, power it off, move the cables back and power OPNsense on.
[opnsense-pi](https://github.com/itpick/opnsense-pi) has OPNsense images for the same boards.
