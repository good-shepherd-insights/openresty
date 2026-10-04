#!/usr/bin/env bash
# Live verification of the GSI edge POC. Asserts the four required behaviours
# against the running containers; exits non-zero on the first failed assertion.
#
#   sudo ./verify.sh            # assumes gsi-edge and gsi-imgproxy are up
#   EDGE_PORT=8611 ./verify.sh  # override the edge listen port
set -uo pipefail

EDGE_PORT="${EDGE_PORT:-8611}"
HOST_HUMAN="${HOST_HUMAN:-poc.test}"
HOST_RENDER="${HOST_RENDER:-r780badk.marylandinsights.com}"
IMG_PATH="${IMG_PATH:-wp-content/uploads/2024/03/an-injured-woman-in-a-plastic-stretcher-after-a-ca-2023-11-27-04-58-12-utc-scaled.jpg}"
ORIGIN_BYTES="${ORIGIN_BYTES:-677187}"

pass=0 fail=0

hdr() { tr -d '\r'; }

# assert <name> <expected> <actual>
assert() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        printf 'ok   %-42s %s\n' "$name" "$got"; pass=$((pass + 1))
    else
        printf 'FAIL %-42s want=%s got=%s\n' "$name" "$want" "$got"; fail=$((fail + 1))
    fi
}

# gsi_path <host> <ua> [cookie]
gsi_path() {
    curl -s -o /dev/null -D- ${2:+-A "$2"} ${3:+-H "Cookie: $3"} -H "Host: $1" \
        "http://127.0.0.1:$EDGE_PORT/" 2>/dev/null | hdr | awk 'tolower($1)=="x-gsi-path:"{print $2}'
}

echo "== config =="
if sudo docker exec gsi-edge openresty -t >/dev/null 2>&1; then
    assert "openresty -t" "ok" "ok"
else
    assert "openresty -t" "ok" "failed"
fi

echo "== routing =="
assert "human request"        "cache"     "$(gsi_path "$HOST_HUMAN")"
assert "logged-in cookie"     "bypass"    "$(gsi_path "$HOST_HUMAN" '' 'wordpress_logged_in_abc=def')"
assert "crawler UA"           "prerender" "$(gsi_path "$HOST_RENDER" 'Googlebot/2.1')"
assert "wp-admin"             "bypass"    \
    "$(curl -s -o /dev/null -D- -H "Host: $HOST_HUMAN" \
        "http://127.0.0.1:$EDGE_PORT/wp-admin/" 2>/dev/null | hdr | awk 'tolower($1)=="x-gsi-path:"{print $2}')"

echo "== cache safety =="
# A logged-in cookie must never be served from, or written to, the cache.
logged=$(curl -s -o /dev/null -D- -H "Host: $HOST_HUMAN" \
    -H 'Cookie: wordpress_logged_in_abc=def' "http://127.0.0.1:$EDGE_PORT/" 2>/dev/null \
    | hdr | awk 'tolower($1)=="x-cache-status:"{print $2}')
assert "logged-in request is not cached" "BYPASS" "${logged:-none}"

echo "== prerender =="
render_bytes=$(curl -s -A 'Googlebot/2.1' -H "Host: $HOST_RENDER" \
    "http://127.0.0.1:$EDGE_PORT/" 2>/dev/null | wc -c | tr -d ' ')
if [ "$render_bytes" -gt 1000 ]; then
    printf 'ok   %-42s %s\n' "prerender returned DOM" "$render_bytes"; pass=$((pass + 1))
else
    printf 'FAIL %-42s want=>1000 got=%s\n' "prerender returned DOM" "$render_bytes"; fail=$((fail + 1))
fi

echo "== unknown host =="
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: nope.invalid' \
    "http://127.0.0.1:$EDGE_PORT/" 2>/dev/null)
# 000 is the correct answer: openresty closes the connection (Lua ngx.exit(444)),
# which curl reports as an empty status line. The `|| echo 000` that used to be
# here appended a second 000 when curl exited non-zero.
assert "unknown host rejected" "000" "$code"

echo "== websocket =="
ws=$(printf 'GET /_stcore/stream HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: v1.streamlit.webSocket\r\n\r\n' \
    "$HOST_HUMAN" | timeout 6 nc 127.0.0.1 "$EDGE_PORT" 2>/dev/null | hdr | awk 'NR==1{print $2}')
assert "websocket upgrade" "101" "$ws"

echo "== imgproxy =="
img_h=$(curl -s -o /dev/null -D- -H "Host: $HOST_HUMAN" -H 'Accept: image/webp,image/*' \
    "http://127.0.0.1:$EDGE_PORT/img/www.tehranilawllc.com/$IMG_PATH" 2>/dev/null | hdr)
ctype=$(printf '%s\n' "$img_h" | awk 'tolower($1)=="content-type:"{print $2}')
ncc=$(printf '%s\n' "$img_h" | grep -ic '^cache-control:')
assert "img content-type" "image/webp" "$ctype"
assert "img single cache-control" "1" "$ncc"
got_bytes=$(curl -s -H "Host: $HOST_HUMAN" -H 'Accept: image/webp,image/*' \
    "http://127.0.0.1:$EDGE_PORT/img/www.tehranilawllc.com/$IMG_PATH" 2>/dev/null | wc -c | tr -d ' ')
if [ "$got_bytes" -lt "$ORIGIN_BYTES" ]; then
    printf 'ok   %-42s %s (< %s)\n' "img smaller than origin" "$got_bytes" "$ORIGIN_BYTES"; pass=$((pass + 1))
else
    printf 'FAIL %-42s got=%s want<%s\n' "img smaller than origin" "$got_bytes" "$ORIGIN_BYTES"; fail=$((fail + 1))
fi

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]