### WAN throughput (wired client, through NAT; internet-server limited)

| State | Test | Mbit/s (app) | Mbit/s (NIC) | WAN ping p50/p95/max ms | loss % | LAN ping p95 ms | CPU avg % (per core) | busiest core % | load1 max | temp max °C | Suricata CPU % |
|---|---|---:|---:|---|---:|---:|---|---:|---:|---:|---:|
| A-ids-deployed | down x1 | 263.5 | 276.2 | 6.547/8.124/9.235 | 0.0 | 3.291 | 36.6 (58/30/32/25) | 85 | 0.56 | 57.85 | 92.5 |
| A-ids-deployed | down x8 | 543.7 | 570.6 | 6.579/13.034/20.504 | 0.0 | 5.392 | 58.1 (91/46/47/48) | 99 | 0.96 | 61.15 | 135.5 |
| A-ids-deployed | up x1 | 529.5 | 555.1 | 6.707/11.859/22.593 | 0.0 | 1.055 | 49.7 (68/87/22/22) | 100 | 1.05 | 62.25 | 109.0 |
| A-ids-deployed | up x8 | 634.7 | 665.9 | 7.093/12.426/38.249 | 0.0 | 5.598 | 78.3 (92/74/74/74) | 99 | 2.3 | 63.9 | 224.0 |
| B-suricata-stopped | down x1 | 50.5 | 54.2 | 7.139/8.26/9.234 | 0.0 | 1.341 | 6.9 (11/7/6/5) | 71 | 0.84 | 58.95 | 0.0 |
| B-suricata-stopped | down x8 | 591.3 | 620.9 | 6.41/10.952/27.04 | 0.0 | 2.013 | 29.8 (67/18/16/17) | 83 | 1.61 | 60.6 | 0.0 |
| B-suricata-stopped | up x1 | 515.9 | 540.8 | 6.74/7.938/34.72 | 0.0 | 1.117 | 32.4 (72/19/18/20) | 77 | 1.29 | 61.15 | 0.0 |
| B-suricata-stopped | up x8 | 718.5 | 754.4 | 10.438/14.041/33.635 | 0.0 | 5.343 | 34.2 (76/19/19/23) | 82 | 1.3 | 62.25 | 0.0 |
| B-suricata-stopped | down x1 | 318.6 | 335.6 | 6.436/7.26/7.779 | 0.0 | 1.243 | 19.8 (42/12/12/13) | 72 | 0.75 | 60.05 | 0.0 |
| B2-suricata-stopped-ntopng-stopped | down x1 | 256.3 | 270.0 | 6.624/8.968/15.35 | 0.0 | 1.166 | 9.7 (35/1/1/1) | 50 | 0.41 | 57.85 | 0.0 |
| B2-suricata-stopped-ntopng-stopped | down x8 | 790.3 | 830.6 | 7.18/19.412/22.091 | 0.0 | 2.275 | 18.8 (71/1/1/1) | 87 | 0.56 | 58.4 | 0.0 |
| B2-suricata-stopped-ntopng-stopped | up x1 | 517.4 | 542.5 | 6.721/10.001/25.417 | 0.0 | 1.049 | 17.7 (67/2/1/1) | 74 | 0.53 | 59.5 | 0.0 |
| B2-suricata-stopped-ntopng-stopped | up x8 | 714.1 | 750.3 | 10.549/13.536/34.705 | 0.0 | 5.126 | 18.3 (69/1/1/1) | 78 | 0.58 | 59.5 | 0.0 |
| C-ips-nfqueue-wan | down x1 | 231.9 | 243.2 | 6.623/16.785/39.571 | 0.0 | 0.652 | 37.7 (62/29/29/31) | 85 | 0.84 | 62.25 | 139.0 |
| C-ips-nfqueue-wan | down x8 | 363.4 | 381.9 | 8.615/49.185/139.715 | 0.0 | 1.062 | 62.4 (91/48/53/58) | 98 | 1.58 | 63.9 | 196.5 |
| C-ips-nfqueue-wan | up x1 | 225.0 | 236.4 | 6.92/19.472/26.753 | 0.0 | 0.904 | 55.8 (68/37/55/63) | 100 | 1.61 | 65.0 | 186.0 |
| C-ips-nfqueue-wan | up x8 | 373.8 | 396.9 | 35.357/119.399/156.069 | 0.0 | 3.409 | 76.0 (87/71/73/74) | 98 | 2.1 | 67.2 | 272.5 |

### Idle baseline

| State | WAN ping p50/p95 ms | LAN ping p50/p95 ms | CPU avg % | temp °C | free mem MB | Suricata RSS MB |
|---|---|---|---:|---:|---:|---:|
| A-ids-deployed | 6.807/7.722 | 0.845/1.673 | 5.9 | 54.7 | 13083 | 1218 |
| A0-ids-deployed-0-rules | None/None | None/None | 6.7 | 53.0 | 14217 | 95 |
| B-suricata-stopped | 6.911/10.567 | 1.193/1.979 | 11.9 | 58.5 | 14269 | 0 |
| B2-suricata-stopped-ntopng-stopped | 7.137/8.041 | 0.83/1.593 | 1.2 | 57.2 | 14682 | 0 |
| C-ips-nfqueue-wan | 7.085/9.292 | 1.04/1.686 | 9.2 | 57.9 | 13184 | 1207 |
| C2-ids-homenet-wan | None/None | None/None | 4.7 | 59.0 | 12878 | 1219 |
| ids-deployed-with-rules | None/None | None/None | None | None | None | None |
| ids-original | None/None | None/None | None | None | None | None |

### LAN -> LAN2 forwarding (iperf3, wired LAN host <-> Mac on Deco Wi-Fi: WI-FI LIMITED)

| State | Direction | Streams | Mbit/s | Retransmits | Router CPU avg % | busiest core % |
|---|---|---:|---:|---:|---:|---:|
| A-ids-deployed | LAN->LAN2 | 1 | 290.4 | 0 | 20.0 | 52 |
| A-ids-deployed | LAN->LAN2 | 4 | 297.1 | 113 | 16.4 | 30 |
| A-ids-deployed | LAN2->LAN | 1 | 318.8 | 0 | 23.4 | 62 |
| A-ids-deployed | LAN2->LAN | 4 | 248.6 | 1 | 19.9 | 59 |
| B-suricata-stopped | LAN->LAN2 | 1 | 297.1 | 28 | 17.7 | 39 |
| B-suricata-stopped | LAN->LAN2 | 4 | 292.0 | 183 | 16.3 | 33 |
| B-suricata-stopped | LAN2->LAN | 1 | 310.1 | 0 | 23.2 | 65 |
| B-suricata-stopped | LAN2->LAN | 4 | 300.4 | 0 | 25.3 | 64 |
