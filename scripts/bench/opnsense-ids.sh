#!/usr/bin/env bash
# OPNsense Suricata control over the REST API (router-specific; VyOS needs its
# own equivalent). Key file: OPN_KEYFILE with key=/secret= lines (never commit).
# Usage:
#   opnsense-ids.sh snapshot DIR          settings + rulesets + policies + status -> DIR
#   opnsense-ids.sh status | stop | start | reconfigure
#   opnsense-ids.sh ips-wan               mode=netmap, interfaces=wan (WAN only!)
#   opnsense-ids.sh rulesets-on f1,f2     enable rulesets by filename
#   opnsense-ids.sh update-rules          download enabled rulesets, wait, reload
#   opnsense-ids.sh homenet-add-wan       add the current public IPv4 /32 to HOME_NET
#                                         (needed for $HOME_NET rules when Suricata sits on a NATed WAN)
#   opnsense-ids.sh drop-policy [f1,f2]   add policy alert->drop for the given rulesets
#                                         (default: all enabled; avoid ET INFO on a household
#                                         router, it matches STUN and would break video calls)
#   opnsense-ids.sh restore DIR           put settings/rulesets/policies back from snapshot
#   opnsense-ids.sh diff DIR              compare live state against snapshot
#   opnsense-ids.sh alerts SINCE_EPOCH    alerts newer than SINCE (JSON lines)
#   opnsense-ids.sh rulecount             installed rule count
#   opnsense-ids.sh watchdog DIR SECS     background: restore DIR after SECS unless DIR/.cancel exists
set -euo pipefail
. "$(dirname "$0")/common.sh"
KEYFILE=${OPN_KEYFILE:-$HOME/workspace/opnsense/OPNsense.localdomain_root_apikey.txt}
K=$(sed -n 's/^key=//p' "$KEYFILE"); S=$(sed -n 's/^secret=//p' "$KEYFILE")
URL=https://$ROUTER_IP/api
get()  { curl -sk --max-time 60 -u "$K:$S" "$URL/$1"; }
post() { curl -sk --max-time 120 -u "$K:$S" -X POST -H 'Content-Type: application/json' -d "${2:-{\}}" "$URL/$1"; }
py() { python3 -c "$@"; }

snapshot() {
  local d=$1; mkdir -p "$d"
  get ids/settings/get > "$d/settings.json"
  get ids/settings/list_rulesets > "$d/rulesets.json"
  get ids/settings/search_policy > "$d/policies.json"
  get ids/service/status > "$d/status.json"
  normalize "$d" > "$d/normalized.json"
}
normalize() {  # selected values only, so two snapshots can be diffed
  py '
import json,sys
d=sys.argv[1]
def flat(o):
    if isinstance(o,dict):
        if o and all(isinstance(v,dict) and "selected" in v for v in o.values()):
            return sorted(k for k,v in o.items() if v["selected"])
        return {k:flat(v) for k,v in o.items()}
    return o
s=flat(json.load(open(d+"/settings.json")))
r=sorted(x["filename"] for x in json.load(open(d+"/rulesets.json"))["rows"] if str(x.get("enabled"))=="1")
p=json.load(open(d+"/policies.json"))["rows"]
st=json.load(open(d+"/status.json")).get("status")
print(json.dumps({"settings":s,"enabled_rulesets":r,"policies":p,"service":st},indent=1,sort_keys=True))' "$1"
}
setting_payload() {  # rebuild a full ids/settings/set payload from a snapshot's settings.json
  py '
import json,sys
def flat(o):
    if isinstance(o,dict):
        if o and all(isinstance(v,dict) and "selected" in v for v in o.values()):
            return ",".join(k for k,v in o.items() if v["selected"])
        return {k:flat(v) for k,v in o.items()}
    return o
print(json.dumps({"ids":{"general":flat(json.load(open(sys.argv[1]))["ids"]["general"])}}))' "$1"
}
wait_idle() { for _ in $(seq 1 90); do st=$(get ids/service/status | py 'import json,sys;print(json.load(sys.stdin).get("status"))'); [ "$st" != "" ] && break; sleep 2; done; echo "$st"; }

case ${1:-} in
  snapshot) snapshot "$2" ;;
  status) get ids/service/status; echo ;;
  stop) post ids/service/stop; echo ;;
  start) post ids/service/start; echo ;;
  reconfigure) post ids/service/reconfigure; echo ;;
  ips-wan)
    post ids/settings/set '{"ids":{"general":{"mode":"netmap","interfaces":"wan"}}}'; echo
    post ids/service/reconfigure; echo ;;
  rulesets-on)
    post "ids/settings/toggle_ruleset/$2/1"; echo ;;
  update-rules)
    post ids/service/update_rules; echo
    # update_rules runs async in configd; wait for the rule count to settle
    prev=-1; for _ in $(seq 1 60); do sleep 5; n=$("$0" rulecount); log "installed rules: $n"; [ "$n" -gt 0 ] && [ "$n" = "$prev" ] && break; prev=$n; done
    post ids/service/reconfigure; echo ;;
  homenet-add-wan)
    hn=$(get ids/settings/get | py 'import json,sys;print(",".join(k for k,v in json.load(sys.stdin)["ids"]["general"]["homenet"].items() if v["selected"]))')
    post ids/settings/set "{\"ids\":{\"general\":{\"homenet\":\"$hn,$(public_ips)/32\"}}}" | sed "s/$(public_ips)/<WAN-IP>/g"; echo
    post ids/service/reconfigure; echo ;;
  drop-policy)
    uu=$(get ids/settings/get_policy | py '
import json,sys
want=[x for x in sys.argv[1].split(",") if x]
rs=json.load(sys.stdin)["policy"]["rulesets"]
print(",".join(k for k,v in rs.items() if not want or v["value"] in want))' "${2:-}")
    post ids/settings/add_policy "{\"policy\":{\"enabled\":\"1\",\"prio\":\"0\",\"action\":\"alert\",\"rulesets\":\"$uu\",\"new_action\":\"drop\",\"description\":\"bench-temp-drop\"}}"; echo
    [ "${NO_RECONFIGURE:-}" ] || { post ids/service/reconfigure; echo; } ;;
  restore)
    d=$2
    post ids/settings/set "$(setting_payload "$d/settings.json")"; echo
    # rulesets: disable those enabled now but not in the snapshot, enable missing ones
    py '
import json,sys
want={x["filename"] for x in json.load(open(sys.argv[1]+"/rulesets.json"))["rows"] if str(x.get("enabled"))=="1"}
now={x["filename"] for x in json.load(sys.stdin)["rows"] if str(x.get("enabled"))=="1"}
print(",".join(sorted(now-want)) or "-"); print(",".join(sorted(want-now)) or "-")' "$d" < <(get ids/settings/list_rulesets) > "$d/.rs"
    off=$(sed -n 1p "$d/.rs"); on=$(sed -n 2p "$d/.rs"); rm -f "$d/.rs"
    [ "$off" != - ] && { post "ids/settings/toggle_ruleset/$off/0"; echo; }
    [ "$on" != - ] && { post "ids/settings/toggle_ruleset/$on/1"; echo; }
    # policies: delete any not in the snapshot
    keep=$(py 'import json,sys;print(" ".join(p["uuid"] for p in json.load(open(sys.argv[1]))["rows"]))' "$d/policies.json")
    for u in $(get ids/settings/search_policy | py 'import json,sys;print(" ".join(p["uuid"] for p in json.load(sys.stdin)["rows"]))'); do
      case " $keep " in *" $u "*) ;; *) post "ids/settings/del_policy/$u"; echo ;; esac
    done
    post ids/service/reconfigure; echo
    want=$(py 'import json,sys;print(json.load(open(sys.argv[1])).get("status"))' "$d/status.json")
    [ "$want" = running ] || { post ids/service/stop; echo; } ;;
  diff)
    t=$(mktemp -d); snapshot "$t"; diff <(normalize "$2") <(normalize "$t") && echo "IDENTICAL to snapshot"; rm -rf "$t" ;;
  alerts)
    post ids/service/query_alerts '{"current":1,"rowCount":500,"searchPhrase":""}' | py '
import json,sys,datetime
since=float(sys.argv[1])
for r in json.load(sys.stdin).get("rows",[]):
    ts=r.get("timestamp","")
    try: t=datetime.datetime.fromisoformat(ts.replace("Z","+00:00")).timestamp()
    except Exception: t=0
    if t>=since:
        print(json.dumps({k:r.get(k) for k in ("timestamp","alert_sid","alert","alert_action","src_ip","src_port","dest_ip","dest_port","proto","in_iface")}))' "$2" ;;
  rulecount)
    post ids/settings/search_installed_rules '{"current":1,"rowCount":1,"searchPhrase":""}' | py 'import json,sys;print(json.load(sys.stdin).get("total",0))' ;;
  watchdog)
    d=$2; secs=$3
    ( sleep "$secs"; if [ ! -e "$d/.cancel" ]; then log "WATCHDOG FIRED: restoring IDS from $d"; "$0" restore "$d" > "$d/watchdog-restore.log" 2>&1; "$0" diff "$d" >> "$d/watchdog-restore.log" 2>&1; fi ) >/dev/null 2>&1 &
    echo "watchdog pid $! (touch $d/.cancel to cancel)" ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
