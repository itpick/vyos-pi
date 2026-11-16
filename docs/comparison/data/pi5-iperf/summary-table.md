| Setup | Test | Mbit/s | TCP retransmits | UDP loss % / jitter ms | Router CPU avg % (per core) | Busiest core % | NIC rx/tx peak Mbit/s | Temp max °C |
|---|---|---:|---:|---|---|---:|---|---:|
| opnsense-lan-ue1 | TCP Mac → router x1 | 591 | 1977 |  | 23.3 (22/26/32/13) | 42 | 633 / 30 | 73.8 |
| opnsense-lan-ue1 | TCP router → Mac x1 | 928 | 99 |  | 23.2 (19/28/25/21) | 44 | 5 / 993 | 73.8 |
| opnsense-lan-ue1 | TCP Mac → router x4 | 600 | 6059 |  | 28.5 (28/34/34/17) | 61 | 641 / 30 | 73.8 |
| opnsense-lan-ue1 | TCP router → Mac x4 | 932 | 337 |  | 24.0 (18/28/30/20) | 46 | 6 / 988 | 73.8 |
| opnsense-lan-ue1 | UDP Mac → router x1 @1G | 953 |  | 0.78 / 0.004 | 20.2 (23/24/21/13) | 52 | 990 / 2 | 73.8 |
| opnsense-lan-ue1 | UDP router → Mac x1 @1G | 930 |  | 0.04 / 0.016 | 40.1 (34/41/45/40) | 77 | 1 / 993 | 76.0 |
| opnsense-lan-ue1-repeat | TCP Mac → router x1 | 594 | 2034 |  | 21.8 (21/29/26/13) | 44 | 708 / 32 | 74.35 |
| opnsense-lan-ue1-repeat | TCP router → Mac x1 | 922 | 87 |  | 33.1 (31/37/37/28) | 78 | 4 / 985 | 74.35 |
| opnsense-lan-ue1-repeat | TCP Mac → router x4 | 612 | 4552 |  | 23.6 (24/29/28/14) | 38 | 656 / 30 | 72.7 |
| opnsense-lan-ue1-repeat | TCP router → Mac x4 | 931 | 326 |  | 23.0 (21/27/25/19) | 43 | 6 / 993 | 72.7 |
| pi5-ubuntu-eth0 | TCP Mac → router x1 | 770 | 231 |  | 21.6 (37/19/14/17) | 56 | 829 / 16 | 66.65 |
| pi5-ubuntu-eth0 | TCP router → Mac x1 | 925 | 796 |  | 11.1 (10/14/12/9) | 37 | 4 / 953 | 65.0 |
| pi5-ubuntu-eth0 | TCP Mac → router x4 | 789 | 293 |  | 29.1 (60/20/20/17) | 63 | 849 / 17 | 65.0 |
| pi5-ubuntu-eth0 | TCP router → Mac x4 | 924 | 2665 |  | 9.3 (15/6/9/6) | 25 | 7 / 957 | 63.9 |
| pi5-ubuntu-eth0 | UDP Mac → router x1 @1G | 954 |  | 0.53 / 0.008 | 20.3 (28/22/19/12) | 35 | 1000 / 0 | 66.1 |
| pi5-ubuntu-eth0 | UDP router → Mac x1 @1G | 954 |  | 0.28 / 0.019 | 14.6 (19/13/16/10) | 39 | 0 / 1007 | 65.0 |
| pi5-vyos-eth0 | TCP Mac → router x1 | 789 | 0 |  | 15.6 (27/15/13/8) | 46 | 877 / 16 | n/a |
| pi5-vyos-eth0 | TCP router → Mac x1 | 911 | 6594 |  | 3.7 (6/4/1/4) | 11 | 3 / 952 | n/a |
| pi5-vyos-eth0 | TCP Mac → router x4 | 727 | 443 |  | 10.0 (17/9/4/9) | 34 | 788 / 16 | n/a |
| pi5-vyos-eth0 | TCP router → Mac x4 | 927 | 4556 |  | 6.2 (7/5/6/6) | 14 | 6 / 960 | n/a |
| pi5-vyos-eth0 | UDP Mac → router x1 @1G | 954 |  | 0.66 / 0.011 | 20.7 (32/13/19/19) | 44 | 998 / 0 | n/a |
| pi5-vyos-eth0 | UDP router → Mac x1 @1G | 955 |  | 0.11 / 0.019 | 20.3 (17/28/20/17) | 44 | 0 / 2012 | n/a |
| pi5-vyos-eth0-repeat | TCP Mac → router x1 | 818 | 232 |  | 22.8 (40/20/17/14) | 47 | 894 / 16 | n/a |
| pi5-vyos-eth0-repeat | TCP router → Mac x1 | 583 | 817 |  | 5.5 (10/4/6/2) | 17 | 4 / 957 | n/a |
| pi5-vyos-eth0-repeat | TCP Mac → router x4 | 739 | 356 |  | 13.5 (24/12/10/8) | 45 | 819 / 17 | n/a |
| pi5-vyos-eth0-repeat | TCP router → Mac x4 | 910 | 24682 |  | 4.7 (9/3/4/3) | 12 | 6 / 959 | n/a |
| pi5-vyos-eth0-just-booted | TCP Mac → router x1 | 807 | 0 |  | n/a |  |  | n/a |
| pi5-vyos-eth0-just-booted | TCP router → Mac x1 | 726 | 751 |  | n/a |  |  | n/a |
| pi5-vyos-eth0-just-booted | TCP Mac → router x4 | 486 | 376 |  | n/a |  |  | n/a |
| pi5-vyos-eth0-just-booted | TCP router → Mac x4 | 587 | 5042 |  | n/a |  |  | n/a |
| pi5-vyos-eth0-just-booted | UDP Mac → router x1 @1G | 826 |  | 0.2 / 0.01 | n/a |  |  | n/a |
| pi5-vyos-eth0-just-booted | UDP router → Mac x1 @1G | 954 |  | 0.15 / 0.018 | n/a |  |  | n/a |
