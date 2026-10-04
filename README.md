# GSI Edge POC — openresty + imgproxy

Fork of `openresty/openresty`: https://github.com/good-shepherd-insights/openresty (parent `openresty/openresty`).

Two containers in front of any customer site, changing nothing on their side:

1. **HTML cache** with a cookie-aware key — a logged-in visitor or a `/wp-admin`
   request never reads or fills the cache.
2. **Image re-encode** — `/wp-content/uploads/*.png|jpg` is rewritten to `/img/`,
   which imgproxy resizes and converts to WebP on the fly.
3. **Crawler switch** — a crawler User-Agent is handed to renderready on
   `127.0.0.1:3305` instead of the origin, and never touches the HTML cache.
4. **WebSocket passthrough** — verified `101 Switching Protocols` against Streamlit.

## Run

```bash
sudo docker run -d --name gsi-imgproxy --network host --restart unless-stopped \
  -e IMGPROXY_BIND=":8090" -e IMGPROXY_AUTO_WEBP=1 -e IMGPROXY_QUALITY=82 \
  -e IMGPROXY_MAX_SRC_SIZE=50 -e IMGPROXY_SAFETY=1 darthsim/imgproxy:latest

sudo docker run -d --name gsi-edge --network host --restart unless-stopped \
  -v "$PWD/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro" \
  -v "$PWD/customers.json:/etc/nginx/customers.json:ro" \
  -v "$PWD/lua:/etc/nginx/lua:ro" \
  -v "$PWD/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
  -e CUSTOMERS_FILE=/etc/nginx/customers.json \
  --entrypoint /bin/sh openresty/openresty:alpine \
  -c 'mkdir -p /tmp/nginx-cache && exec openresty -g "daemon off;"'
```

Ports on this host: edge `8611` (8610 is already ua-switch), imgproxy `8090`
(8080 is already taken). Both containers use host networking so the crawler
branch reaches renderready at `127.0.0.1:3305` without publishing that port.

## Onboarding a customer

Append one entry to `customers.json`, reload. No code change.

```json
{ "hostname": "example.com", "origin": "https://origin.example.com",
  "renderReady": true, "credit": "" }
```

`renderReady` sends crawlers to the prerenderer. `credit` is contractual footer
text — leave empty unless the customer signed for it. Never injected at the edge.

## Verify

`verify.sh` asserts every behaviour below against the running containers and exits
non-zero on the first failure. It is wired into `hermes verify` via
`.hermes/environment.json`.

```bash
./verify.sh                # 12 assertions, ~11s
hermes verify --skip-start # same thing, records the evidence
```

## Verified live (not just config-tested)

Every line below was executed against the running containers on this host.

| Check | Result |
|---|---|
| Human request, `Host: poc.test` | `200`, `X-GSI-Path: cache` |
| Second human request | `X-Cache-Status: MISS` → origin sends `no-cache` (Streamlit); a WordPress origin populates the cache |
| Logged-in cookie (`wordpress_logged_in_abc`) | `X-GSI-Path: bypass` |
| `/wp-admin/` | `X-GSI-Path: bypass` |
| `Googlebot/2.1` on a `renderReady: true` host | `X-GSI-Path: prerender`, 10,143 bytes, `X-Cache-Status: BYPASS` |
| Unknown host | connection closed, no upstream (Lua `ngx.exit(444)`) |
| WebSocket `/_stcore/stream` | `101 Switching Protocols` |
| imgproxy via `/img/<host>/<path>` | `200`, `image/webp`, 327,360 bytes vs 677,187 at the origin |
| imgproxy at `size:800:0` direct | 94,250 bytes |
| `openresty -t` | `syntax is ok` / `test is successful` |

## Gotchas found while building this

- **No `if` blocks.** nginx rejects `proxy_set_header` and the `proxy_cache_*`
  directives inside `if`. Both branches are selected by one variable set in
  `access_by_lua_block`.
- **`sub_filter` uses positional `$1..$9`**, not named captures.
- **`$cookie_<name>` does not work for WordPress** — the cookie is
  `wordpress_logged_in_<hash>`, a different name every install. Match `$http_cookie`.
- **`lua_package_cpath` is empty in the alpine image**, so the Lua module lives in
  `lua/gsi/` (dots become slashes) and `lua_package_path` points at it.
- **`env` is not visible to `init_by_lua`**, so the Lua module defaults
  `CUSTOMERS_FILE` itself.
- **imgproxy URL grammar** is `%signature/%processing_options/plain/%base64url`.
  `size:W:0` works, `rs:fit-in:W:0` does not. Signature checking is off, so the
  signature slot can be the literal `unsafe`.
- **Two `Cache-Control` headers** on `/img/` until `proxy_hide_header Cache-Control`
  is set on that location — imgproxy sets its own.

## Why openresty and not the alternatives

Our four requirements need `proxy_cache`, `sub_filter`, a UA `map`, WebSocket
passthrough, and per-customer Lua. openresty is nginx + LuaJIT in one binary, so
all of it is one readable file.

- Envoy — https://github.com/envoyproxy/envoy — extension model makes each
  feature a separate compiled component.
- Kong / APISIX — API gatewaying, not HTML body rewriting.
- Caddy — https://github.com/caddyserver/caddy — no `sub_filter` equivalent.
- Traefik — https://github.com/traefik/traefik — routing labels, not HTML mutation.
- HAProxy — https://github.com/haproxy/haproxy — cannot rewrite a response body.
- plain nginx — https://github.com/nginx/nginx — openresty minus the Lua.
- Varnish — canonical repo moved to https://gitlab.com/varnishcache/varnish-cache;
  the GitHub mirror is archived.

## Requirements before serving a real customer

1. DNS authority over the customer domain (nameserver move, or Cloudflare for SaaS).
2. Cache policy must respect `Set-Cookie` and bypass `wp-admin`, `wp-login`,
   `/wp-content/uploads`, `/wp-content/plugins`.
3. Per-customer purge — `POST /__purge?host=` (localhost only today).
4. Sign imgproxy URLs once keys are configured; `unsafe` is fine only while the
   service is bound to loopback.
5. Contractual footer credit, opt-out-able, never injected where the customer
   cannot see it.

## renderready note

`lukapozega/renderready` is the crawler path. It is small: 3 stars, 45 npm
downloads/month, MIT, v1.0.0, created 2026-08-06. It works and runs in production
on this box. Pin the version and mirror it internally.

`removeScriptTags` defaults to `true`, so its output is for crawlers only. Never
serve it to humans.