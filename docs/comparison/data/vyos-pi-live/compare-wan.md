| Suricata state (OPNsense / VyOS) | Test | OPNsense Mbit/s | VyOS Mbit/s | OPNsense WAN ping p50 / p95 ms | VyOS WAN ping p50 / p95 ms | OPNsense CPU avg / busiest core % | VyOS CPU avg / busiest core % | OPNsense Suricata CPU % | VyOS Suricata CPU % |
|---|---|---:|---:|---|---|---|---|---:|---:|
| Stopped (B / B) | down x1 | 230 | 319 | 7.2 / 8.4 | 6.4 / 7.3 | 16 / 39 | 20 / 72 | 0 | 0 |
| Stopped (B / B) | down x8 | 664 | 591 | 7.4 / 19.7 | 6.4 / 11.0 | 26 / 51 | 30 / 83 | 0 | 0 |
| Stopped (B / B) | up x1 | 338 | 516 | 7.4 / 16.5 | 6.7 / 7.9 | 15 / 30 | 32 / 77 | 0 | 0 |
| Stopped (B / B) | up x8 | 441 | 718 | 7.7 / 13.5 | 10.4 / 14.0 | 22 / 45 | 34 / 82 | 0 | 0 |
| IDS with ET Open rules (C / A) | down x1 | 184 | 264 | 7.2 / 9.5 | 6.5 / 8.1 | 24 / 46 | 37 / 85 | 27 | 92 |
| IDS with ET Open rules (C / A) | down x8 | 478 | 544 | 7.3 / 15.4 | 6.6 / 13.0 | 56 / 95 | 58 / 99 | 62 | 136 |
| IDS with ET Open rules (C / A) | up x1 | 268 | 530 | 7.4 / 14.7 | 6.7 / 11.9 | 33 / 47 | 50 / 100 | 61 | 109 |
| IDS with ET Open rules (C / A) | up x8 | 340 | 635 | 7.5 / 14.8 | 7.1 / 12.4 | 38 / 56 | 78 / 99 | 70 | 224 |
| IPS on WAN (D / C) | down x1 | 209 | 232 | 13.6 / 62.4 | 6.6 / 16.8 | 35 / 64 | 38 / 85 | 53 | 139 |
| IPS on WAN (D / C) | down x8 | 264 | 363 | 26.6 / 59.3 | 8.6 / 49.2 | 40 / 57 | 62 / 98 | 77 | 196 |
| IPS on WAN (D / C) | up x1 | 161 | 225 | 21.9 / 57.7 | 6.9 / 19.5 | 39 / 65 | 56 / 100 | 72 | 186 |
| IPS on WAN (D / C) | up x8 | 192 | 374 | 34.9 / 54.0 | 35.4 / 119.4 | 41 / 71 | 76 / 98 | 79 | 272 |
