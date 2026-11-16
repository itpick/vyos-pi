#!/usr/bin/env bash
# IDS/IPS detection probes from the wired client. Records what the client saw
# (HTTP code, timing, body marker); alerts are pulled from the router
# separately (opnsense-ids.sh alerts / VyOS eve.json).
# Usage: detection.sh OUTDIR   -> OUTDIR/detect.jsonl
set -uo pipefail
. "$(dirname "$0")/common.sh"
OUT=${1:?outdir}; mkdir -p "$OUT"
J="$OUT/detect.jsonl"
EICAR='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
EICAR_B64=$(printf '%s' "$EICAR" | base64 | tr '+/' '-_')
rec() { python3 -c 'import json,sys;print(json.dumps(dict(zip(sys.argv[1::2],sys.argv[2::2]))))' "$@" >> "$J"; tail -1 "$J" >&2; }
http() {  # name url [extra curl args...]
  local name=$1 url=$2; shift 2; local t0 res body
  t0=$(now)
  res=$(curl --interface "$WIRED_IF" -s --max-time 10 -o "$OUT/.body" -w '%{http_code} %{time_total} %{size_download}' "$@" "$url"); rc=$?
  body=$(head -c 120 "$OUT/.body" 2>/dev/null | tr -c '[:print:]' ' ')
  rec probe "$name" t0 "$t0" curl_rc "$rc" result "$res" body "$body"; rm -f "$OUT/.body"
}
# testmynids.org/uid is the classic trigger for sid 2100498 (GPL ATTACK_RESPONSE id
# check returned root), but the domain is parked now (no payload); httpbin
# echoes the same "uid=0(root)" bytes over plain HTTP.
http testmynids_uid http://testmynids.org/uid/index.html
http uid_root_httpbin "http://httpbin.org/base64/$(printf 'uid=0(root) gid=0(root) groups=0(root)' | base64)"
http eicar_http "http://httpbin.org/base64/$EICAR_B64"
http nikto_ua http://testmynids.org/ -A 'Mozilla/5.00 (Nikto/2.1.6) (Evasions:None) (Test:Port Check)'
http nmap_nse_ua http://testmynids.org/ -A 'Mozilla/5.0 (compatible; Nmap Scripting Engine; https://nmap.org/book/nse.html)'
http curl_python_ua http://testmynids.org/ -A 'python-requests/2.0'
for q in duckdns.org test.duckdns.org example.ddns.net facebookcorewwwi.onion onion.to example.onion.ws pool.minexmr.com api.ipify.org; do
  t0=$(now)
  a=$(dig -b "${SRC_IP:-$(ipconfig getifaddr "$WIRED_IF")}" @"${DNS_TARGET:-8.8.8.8}" +time=3 +tries=1 +short "$q" A 2>&1 | head -2 | tr '\n' ' ')
  rec probe "dns:$q" t0 "$t0" answer "$a"
done
t0=$(now)
nm=$(nmap -e "$WIRED_IF" -Pn -sT -sV --script=http-title -p 22,80,9929 --max-retries 1 --host-timeout 60s scanme.nmap.org 2>&1 | grep -E '^[0-9]+/tcp|http-title|Nmap done' | tr '\n' ';')
rec probe nmap_scanme t0 "$t0" result "$nm"
redact "$J"
