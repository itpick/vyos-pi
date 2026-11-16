interfaces {
    loopback lo {
    }
    ethernet eth0 {
        description "WAN"
        address "dhcp"
        address "dhcpv6"
        dhcpv6-options {
            pd 0 {
                length "56"
                interface eth1 {
                    address "1"
                    sla-id "0"
                }
            }
        }
    }
    ethernet eth1 {
        description "LAN"
        hw-id "02:00:00:00:aa:01"
        address "10.20.0.1/24"
        vif 30 {
            description "Guest"
            address "10.20.30.1/24"
        }
    }
    ethernet eth2 {
        description "IoT"
        hw-id "02:00:00:00:aa:02"
        address "10.20.1.1/24"
    }
    wireguard wg0 {
        description "home"
        address "10.99.0.1/24"
        port "51820"
        private-key "KJT+GT/UEa5Io3B7Prt6y7dqaP6fGniuUFKdO0XXF1Y="
        peer phone {
            public-key "D/De8UyEbUBOnqLKRCUErbVR7YOyvH+yRpQP2WvoRsw="
            allowed-ips "10.99.0.2/32"
            persistent-keepalive "25"
        }
        peer laptop {
            public-key "SJg0KnIHbyKAFOM0WfNFTwL2HiKvpv6IKUQNCuetooQ="
            preshared-key "HBmjrScYZg3qGpeT/dMPLsscBKCwIk/ReASGbhrKx2k="
            allowed-ips "10.99.0.3/32"
        }
    }
}
service {
    ntp {
        allow-client {
            address "127.0.0.0/8"
            address "169.254.0.0/16"
            address "10.0.0.0/8"
            address "172.16.0.0/12"
            address "192.168.0.0/16"
            address "::1/128"
            address "fe80::/10"
            address "fc00::/7"
        }
        server 0.pool.ntp.org {
        }
        server 1.pool.ntp.org {
        }
    }
    router-advert {
        interface eth1 {
            prefix ::/64 {
            }
        }
    }
    dhcp-server {
        shared-network-name LAN {
            subnet 10.20.0.0/24 {
                subnet-id "1"
                description "LAN"
                option {
                    default-router "10.20.0.1"
                    name-server "10.20.0.1"
                    ntp-server "10.20.0.1"
                    domain-name "home.example"
                }
                lease "7200"
                range 0 {
                    start "10.20.0.100"
                    stop "10.20.0.199"
                }
                static-mapping server {
                    ip-address "10.20.0.50"
                    mac "02:00:00:00:00:50"
                    description "Home server"
                }
                static-mapping nas {
                    ip-address "10.20.0.51"
                    mac "02:00:00:00:00:51"
                }
            }
        }
        shared-network-name IOT {
            subnet 10.20.1.0/24 {
                subnet-id "2"
                description "IoT"
                option {
                    default-router "10.20.1.1"
                    name-server "10.20.1.1"
                }
                lease "7200"
                range 0 {
                    start "10.20.1.100"
                    stop "10.20.1.199"
                }
                static-mapping printer {
                    ip-address "10.20.1.40"
                    mac "02:00:00:00:01:40"
                }
            }
        }
        shared-network-name GUEST {
            subnet 10.20.30.0/24 {
                subnet-id "3"
                description "Guest"
                option {
                    default-router "10.20.30.1"
                    name-server "10.20.30.1"
                }
                lease "7200"
                range 0 {
                    start "10.20.30.100"
                    stop "10.20.30.199"
                }
            }
        }
        hostfile-update
    }
    dns {
        forwarding {
            listen-address "10.20.0.1"
            listen-address "10.20.1.1"
            listen-address "10.20.30.1"
            allow-from "10.20.0.0/24"
            allow-from "10.20.1.0/24"
            allow-from "10.20.30.0/24"
            allow-from "10.99.0.0/24"
            cache-size "10000"
            dnssec "validate"
            domain corp.example {
                name-server "192.0.2.53"
            }
        }
    }
    ssh {
        port "22"
        listen-address "10.20.0.1"
        disable-password-authentication
    }
    suricata {
        interface "eth0"
        address-group home-net {
            address "10.20.0.0/16"
            address "10.99.0.0/24"
        }
        address-group external-net {
            group "!home-net"
        }
        address-group http-servers {
            group "home-net"
        }
        address-group smtp-servers {
            group "home-net"
        }
        address-group sql-servers {
            group "home-net"
        }
        address-group dns-servers {
            group "home-net"
        }
        address-group telnet-servers {
            group "home-net"
        }
        address-group aim-servers {
            group "home-net"
        }
        address-group dc-servers {
            group "home-net"
        }
        address-group dnp3-server {
            group "home-net"
        }
        address-group dnp3-client {
            group "home-net"
        }
        address-group modbus-client {
            group "home-net"
        }
        address-group modbus-server {
            group "home-net"
        }
        address-group enip-client {
            group "home-net"
        }
        address-group enip-server {
            group "home-net"
        }
        port-group http-ports {
            port "80"
        }
        port-group shellcode-ports {
            group "!http-ports"
        }
        port-group oracle-ports {
            port "1521"
        }
        port-group ssh-ports {
            port "22"
        }
        port-group dnp3-ports {
            port "20000"
        }
        port-group modbus-ports {
            port "502"
        }
        port-group file-data-ports {
            port "110"
            port "143"
            group "http-ports"
        }
        port-group ftp-ports {
            port "21"
        }
        port-group geneve-ports {
            port "6081"
        }
        port-group vxlan-ports {
            port "4789"
        }
        port-group teredo-ports {
            port "3544"
        }
        log {
            eve {
                type "alert"
                type "tls"
            }
        }
    }
}
system {
    config-management {
        commit-revisions "100"
    }
    console {
        device ttyAMA0 {
            kernel
            speed "115200"
        }
    }
    host-name "router"
    login {
        operator-group default {
            command-policy {
                allow "*"
            }
        }
        user vyos {
            authentication {
                encrypted-password "$6$QxPS.uk6mfo$9QBSo8u1FkH16gMyAVhus6fU3LOzvLR9Z9.82m3tiHFAxTtIkhaZSWssSgzt4v4dGAL8rhVQxTg0oAG9/q11h/"
                plaintext-password ""
                public-keys admin-example.net {
                    key "AAAAC3NzaC1lZDI1NTE5AAAAINzPPTdfR/vYnJfiJQAc7jpv+0r7tQcaCe7RORF9sAPt"
                    type "ssh-ed25519"
                }
            }
        }
    }
    option {
        reboot-on-upgrade-failure "5"
    }
    syslog {
        local {
            facility all {
                level "info"
            }
            facility local7 {
                level "debug"
            }
        }
        remote 10.20.0.50 {
            port "514"
            facility all {
                level "info"
            }
        }
    }
    static-host-mapping {
        host-name nas.home.example {
            inet "10.20.0.51"
        }
    }
    domain-name "home.example"
    time-zone "America/Chicago"
    flow-accounting {
        netflow {
            interface "eth1"
            interface "eth0"
            version "9"
            server 192.0.2.50 {
                port "2055"
            }
            active-timeout "1800"
            inactive-timeout "15"
        }
        enable-egress
    }
    task-scheduler {
        task suricata-update {
            interval "1d"
            executable {
                path "/usr/libexec/vyos/op_mode/update_suricata.sh"
            }
        }
    }
}
firewall {
    group {
        address-group WebServer {
            address "10.20.0.50"
            description "Home server"
        }
        address-group Printers {
            address "10.20.1.40"
            address "10.20.1.41"
            description "Printers: no internet"
        }
        network-group BlockedNets {
            network "198.51.100.0/24"
            network "203.0.113.0/25"
            description "Networks nobody inside may reach"
        }
        remote-group SpamhausDROP {
            url "https://www.spamhaus.org/drop/drop.txt"
            interval "86400"
            description "Spamhaus DROP"
        }
        remote-group FeodoTracker {
            url "https://feodotracker.abuse.ch/downloads/ipblocklist.txt"
            interval "43200"
            description "abuse.ch Feodo C2 servers"
        }
        mac-group TrustedIoT {
            mac-address "02:00:00:00:10:01"
            mac-address "02:00:00:00:10:02"
            description "IoT devices allowed to reach the LAN"
        }
        port-group CastPorts {
            port "8008-8009"
            port "8443"
        }
        remote-group OldVPNPeers {
            url "https://lists.example.net/vpn-peers.txt"
            interval "86400"
        }
        network-group OPN-PRIVATE {
            network "10.0.0.0/8"
            network "172.16.0.0/12"
            network "192.168.0.0/16"
        }
        network-group OPN-BOGONS {
            network "0.0.0.0/8"
            network "100.64.0.0/10"
            network "127.0.0.0/8"
            network "169.254.0.0/16"
            network "192.0.0.0/24"
            network "192.0.2.0/24"
            network "198.18.0.0/15"
            network "198.51.100.0/24"
            network "203.0.113.0/24"
            network "224.0.0.0/4"
            network "240.0.0.0/4"
        }
        interface-group LAN_IOT {
            interface "eth1"
            interface "eth2"
        }
    }
    global-options {
        state-policy {
            established {
                action "accept"
            }
            related {
                action "accept"
            }
            invalid {
                action "drop"
            }
        }
    }
    ipv4 {
        input {
            filter {
                default-action "drop"
                rule 10 {
                    action "accept"
                    inbound-interface {
                        name "lo"
                    }
                    description "loopback"
                }
                rule 20 {
                    action "drop"
                    inbound-interface {
                        name "eth0"
                    }
                    source {
                        group {
                            network-group "OPN-PRIVATE"
                        }
                    }
                    description "Block private networks on wan"
                }
                rule 30 {
                    action "drop"
                    inbound-interface {
                        name "eth0"
                    }
                    source {
                        group {
                            network-group "OPN-BOGONS"
                        }
                    }
                    description "Block bogon networks on wan"
                }
                rule 40 {
                    action "accept"
                    protocol "tcp"
                    destination {
                        port "22"
                    }
                    inbound-interface {
                        name "eth1"
                    }
                    description "anti-lockout: SSH from lan"
                }
                rule 50 {
                    action "accept"
                    protocol "udp"
                    destination {
                        port "67"
                    }
                    inbound-interface {
                        name "eth1"
                    }
                    description "DHCP server on lan"
                }
                rule 60 {
                    action "accept"
                    protocol "udp"
                    destination {
                        port "67"
                    }
                    inbound-interface {
                        name "eth2"
                    }
                    description "DHCP server on opt1"
                }
                rule 70 {
                    action "accept"
                    protocol "udp"
                    destination {
                        port "67"
                    }
                    inbound-interface {
                        name "eth1.30"
                    }
                    description "DHCP server on opt2"
                }
                rule 80 {
                    action "accept"
                    description "WireGuard in"
                    protocol "udp"
                    log
                    inbound-interface {
                        name "eth0"
                    }
                    destination {
                        port "51820"
                    }
                }
                rule 90 {
                    action "accept"
                    description "Old VPN peers (alias disabled)"
                    protocol "udp"
                    disable
                    inbound-interface {
                        name "eth0"
                    }
                    source {
                        group {
                            remote-group "OldVPNPeers"
                        }
                    }
                    destination {
                        port "1194"
                    }
                }
                rule 100 {
                    action "accept"
                    description "WireGuard clients to anywhere"
                    inbound-interface {
                        name "wg0"
                    }
                }
                rule 110 {
                    action "drop"
                    description "Printers: nothing but the LAN"
                    log
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        group {
                            address-group "Printers"
                        }
                    }
                    destination {
                        address "!10.20.0.0/24"
                    }
                }
                rule 120 {
                    action "accept"
                    description "IoT: DNS to the router"
                    protocol "tcp_udp"
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        address "10.20.1.0/24"
                    }
                    destination {
                        port "53"
                    }
                }
                rule 130 {
                    action "accept"
                    description "Trusted IoT to the LAN (cast ports)"
                    protocol "tcp"
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        group {
                            mac-group "TrustedIoT"
                        }
                    }
                    destination {
                        address "10.20.0.0/24"
                        group {
                            port-group "CastPorts"
                        }
                    }
                }
                rule 140 {
                    action "drop"
                    description "IoT: nothing else to the LAN"
                    log
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        address "10.20.1.0/24"
                    }
                    destination {
                        address "10.20.0.0/24"
                    }
                }
                rule 150 {
                    action "drop"
                    description "Guests: internet only"
                    log
                    inbound-interface {
                        name "eth1.30"
                    }
                    source {
                        address "10.20.30.0/24"
                    }
                    destination {
                        address "10.20.0.0/16"
                    }
                }
                rule 160 {
                    action "accept"
                    description "Policy route via a backup uplink (off)"
                    disable
                    inbound-interface {
                        name "eth1"
                    }
                    source {
                        address "10.20.0.0/24"
                    }
                }
                rule 170 {
                    action "accept"
                    description "Default allow LAN to any rule"
                    inbound-interface {
                        name "eth1"
                    }
                    source {
                        address "10.20.0.0/24"
                    }
                }
                rule 180 {
                    action "accept"
                    description "pass on opt1 (rule 16)"
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        address "10.20.1.0/24"
                    }
                }
                rule 190 {
                    action "accept"
                    description "pass on opt2 (rule 17)"
                    inbound-interface {
                        name "eth1.30"
                    }
                    source {
                        address "10.20.30.0/24"
                    }
                }
            }
        }
        forward {
            filter {
                default-action "drop"
                rule 10 {
                    action "drop"
                    inbound-interface {
                        name "eth0"
                    }
                    source {
                        group {
                            network-group "OPN-PRIVATE"
                        }
                    }
                    description "Block private networks on wan"
                }
                rule 20 {
                    action "drop"
                    inbound-interface {
                        name "eth0"
                    }
                    source {
                        group {
                            network-group "OPN-BOGONS"
                        }
                    }
                    description "Block bogon networks on wan"
                }
                rule 30 {
                    action "accept"
                    connection-status {
                        nat "destination"
                    }
                    description "port forwards (nat destination)"
                }
                rule 40 {
                    action "accept"
                    description "WireGuard clients to anywhere"
                    inbound-interface {
                        name "wg0"
                    }
                }
                rule 50 {
                    action "drop"
                    description "Block outbound to Spamhaus DROP"
                    log
                    inbound-interface {
                        group "LAN_IOT"
                    }
                    destination {
                        group {
                            remote-group "SpamhausDROP"
                        }
                    }
                }
                rule 60 {
                    action "drop"
                    description "Block outbound to Feodo C2"
                    log
                    inbound-interface {
                        group "LAN_IOT"
                    }
                    destination {
                        group {
                            remote-group "FeodoTracker"
                        }
                    }
                }
                rule 70 {
                    action "drop"
                    description "Block outbound to BlockedNets"
                    log
                    inbound-interface {
                        group "LAN_IOT"
                    }
                    destination {
                        group {
                            network-group "BlockedNets"
                        }
                    }
                }
                rule 80 {
                    action "drop"
                    description "Printers: nothing but the LAN"
                    log
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        group {
                            address-group "Printers"
                        }
                    }
                    destination {
                        address "!10.20.0.0/24"
                    }
                }
                rule 90 {
                    action "accept"
                    description "Trusted IoT to the LAN (cast ports)"
                    protocol "tcp"
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        group {
                            mac-group "TrustedIoT"
                        }
                    }
                    destination {
                        address "10.20.0.0/24"
                        group {
                            port-group "CastPorts"
                        }
                    }
                }
                rule 100 {
                    action "drop"
                    description "IoT: nothing else to the LAN"
                    log
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        address "10.20.1.0/24"
                    }
                    destination {
                        address "10.20.0.0/24"
                    }
                }
                rule 110 {
                    action "drop"
                    description "Guests: internet only"
                    log
                    inbound-interface {
                        name "eth1.30"
                    }
                    source {
                        address "10.20.30.0/24"
                    }
                    destination {
                        address "10.20.0.0/16"
                    }
                }
                rule 120 {
                    action "accept"
                    description "Policy route via a backup uplink (off)"
                    disable
                    inbound-interface {
                        name "eth1"
                    }
                    source {
                        address "10.20.0.0/24"
                    }
                }
                rule 130 {
                    action "accept"
                    description "Default allow LAN to any rule"
                    inbound-interface {
                        name "eth1"
                    }
                    source {
                        address "10.20.0.0/24"
                    }
                }
                rule 140 {
                    action "accept"
                    description "pass on opt1 (rule 16)"
                    inbound-interface {
                        name "eth2"
                    }
                    source {
                        address "10.20.1.0/24"
                    }
                }
                rule 150 {
                    action "accept"
                    description "pass on opt2 (rule 17)"
                    inbound-interface {
                        name "eth1.30"
                    }
                    source {
                        address "10.20.30.0/24"
                    }
                }
                rule 160 {
                    action "accept"
                    description "old SSH forward (off)"
                    protocol "tcp"
                    disable
                    inbound-interface {
                        name "eth0"
                    }
                    destination {
                        address "10.20.0.50"
                        port "22"
                    }
                }
            }
        }
    }
    ipv6 {
        input {
            filter {
                default-action "drop"
                rule 10 {
                    action "accept"
                    inbound-interface {
                        name "lo"
                    }
                    description "loopback"
                }
                rule 20 {
                    action "accept"
                    protocol "ipv6-icmp"
                    description "ICMPv6 (neighbour discovery, router advertisements)"
                }
                rule 30 {
                    action "accept"
                    protocol "udp"
                    destination {
                        port "546"
                    }
                    inbound-interface {
                        name "eth0"
                    }
                    description "DHCPv6 client on wan"
                }
                rule 40 {
                    action "accept"
                    description "Default allow LAN IPv6 to any rule"
                    inbound-interface {
                        name "eth1"
                    }
                }
            }
        }
        forward {
            filter {
                default-action "drop"
                rule 10 {
                    action "accept"
                    protocol "ipv6-icmp"
                    description "ICMPv6"
                }
                rule 20 {
                    action "accept"
                    description "Default allow LAN IPv6 to any rule"
                    inbound-interface {
                        name "eth1"
                    }
                }
            }
        }
    }
}
nat {
    destination {
        rule 10 {
            description "HTTPS to the home server"
            inbound-interface {
                name "eth0"
            }
            protocol "tcp"
            destination {
                port "443"
            }
            translation {
                address "10.20.0.50"
                port "443"
            }
        }
        rule 20 {
            description "Game server (off)"
            disable
            inbound-interface {
                name "eth0"
            }
            protocol "udp"
            destination {
                port "27015"
            }
            translation {
                address "10.20.0.60"
                port "27015"
            }
        }
    }
    source {
        rule 10 {
            description "WireGuard clients out the WAN"
            outbound-interface {
                name "eth0"
            }
            source {
                address "10.99.0.0/24"
            }
            translation {
                address "masquerade"
            }
        }
        rule 100 {
            description "automatic outbound NAT: 10.20.0.0/24 out wan"
            outbound-interface {
                name "eth0"
            }
            source {
                address "10.20.0.0/24"
            }
            translation {
                address "masquerade"
            }
        }
        rule 110 {
            description "automatic outbound NAT: 10.20.1.0/24 out wan"
            outbound-interface {
                name "eth0"
            }
            source {
                address "10.20.1.0/24"
            }
            translation {
                address "masquerade"
            }
        }
        rule 120 {
            description "automatic outbound NAT: 10.20.30.0/24 out wan"
            outbound-interface {
                name "eth0"
            }
            source {
                address "10.20.30.0/24"
            }
            translation {
                address "masquerade"
            }
        }
        rule 130 {
            description "automatic outbound NAT: 10.99.0.0/24 out wan"
            outbound-interface {
                name "eth0"
            }
            source {
                address "10.99.0.0/24"
            }
            translation {
                address "masquerade"
            }
        }
    }
}
// Warning: Do not remove the following line.
// vyos-config-version: "bgp@8:broadcast-relay@1:cluster@2:config-management@2:conntrack@6:conntrack-sync@2:container@3:dhcp-relay@2:dhcp-server@11:dhcpv6-server@6:dns-dynamic@5:dns-forwarding@4:firewall@20:flow-accounting@3:https@7:ids@2:interfaces@34:ipoe-server@4:ipsec@14:isis@3:l2tp@10:lldp@3:mdns@1:monitoring@3:nat@8:nat66@3:nhrp@1:ntp@3:openconnect@3:openvpn@6:ospf@4:pim@1:pki@1:policy@9:pppoe-server@13:pptp@6:qos@3:quagga@13:reverse-proxy@3:rip@1:rpki@2:snmp@3:ssh@3:sstp@7:system@33:vpp@6:vrf@4:vrrp@4:vyos-accel-ppp@2:wanloadbalance@4:webproxy@2"
// Release version: 2026.11.16-1
