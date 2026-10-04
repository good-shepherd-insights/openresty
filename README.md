# GSI Edge POC — openresty + imgproxy

**Status: working POC, parked.** Proven live, 12/12 assertions passing. One path
unproven (the cache has never served a `HIT` — see below). Not deployed to
anything but this host.

Fork of `openresty/openresty`: https://github.com/good-shepherd-insights/openresty (parent `openresty/openresty`).

Two containers in front of any customer site, changing nothing on their side:

1. **HTML cache** with a cookie-aware key — a logged-in visitor or a `/wp-admin`
   request never reads or fills the cache.
2. **Image re-encode** — `/wp-content/uploads/*.png|jpg` is rewritten to `/img/`,
   which imgproxy resizes and converts to WebP on the fly. **WordPress-shaped, see
   "What is not yet generalised" below.**
3. **Crawler switch** — a crawler User-Agent is handed to renderready on
   `127.0.0.1:3305` instead of the origin, and never touches the HTML cache.
4. **WebSocket passthrough** — verified `101 Switching Protocols` against Streamlit.

Features 1, 3 and 4 are platform-agnostic. Only feature 2 matches a
WordPress-specific path.

## Run

```bash
sudo docker run -d --name gsi-imgproxy --network host --restart unless-stopped \
  -e IMGPROXY_BIND="127.0.0.1:8090" -e IMGPROXY_AUTO_WEBP=1 -e IMGPROXY_QUALITY=82 \
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

## Purge

```bash
curl -X POST "http://127.0.0.1:8611/__purge?host=example.com"
# -> purged example.com version 0 -> 1
```

Loopback only (`allow 127.0.0.1`). Purging bumps a per-host counter in the
`purgever` shared dict; that counter is the first component of both cache keys,
so every previously cached object for that host becomes unreachable and ages out
via `inactive=24h`. Nothing is deleted synchronously — a purge is instant for
visitors, not for disk.

Do not "fix" this by declaring `lua_shared_dict htmlcache`. A `keys_zone` and a
`lua_shared_dict` are the same shared memory zone, and nginx rejects the second
declaration with `the shared memory zone "htmlcache" is already declared for a
different use`, which crash-loops the container. Purging a `proxy_cache` zone from
Lua needs `ngx.cache`, which only covers Lua-created caches. Versioning is the
approach that actually runs.

## What is not yet generalised

The image rewrite matches the literal string `/wp-content/uploads/`:

```
sub_filter 'src="/wp-content/uploads/([^"?]+\.(png|jpg|jpeg))' 'src="/img/$host/$1"';
```

Against a site whose images live elsewhere it matches nothing. Measured on
goodshepherdinsights.com: 13 assets, 1,121 KB, top 8 all `cdn.sanity.io` between
72 KB and 162 KB — the rewrite would catch zero of them.

The general form is "rewrite any image URL not already served by a known image
CDN", which covers Sanity, Cloudinary and S3 while skipping what is already
optimised. That is a regex change, not a redesign — but it is not done.

The cache and the crawler switch are unaffected; they are platform-agnostic.

## Verified live (not just config-tested)

Every line below was executed against the running containers on this host.

| Check | Result |
|---|---|
| Human request, `Host: poc.test` | `200`, `X-GSI-Path: cache` |
| Second human request | `X-Cache-Status: MISS` — see "The one unproven path" below |
| Logged-in cookie (`wordpress_logged_in_abc`) | `X-GSI-Path: bypass` |
| `/wp-admin/` | `X-GSI-Path: bypass` |
| `Googlebot/2.1` on a `renderReady: true` host | `X-GSI-Path: prerender`, 10,143 bytes, `X-Cache-Status: BYPASS` |
| Unknown host | connection closed, no upstream (Lua `ngx.exit(444)`) |
| WebSocket `/_stcore/stream` | `101 Switching Protocols` |
| imgproxy via `/img/<host>/<path>` | `200`, `image/webp`, 327,360 bytes vs 677,187 at the origin |
| imgproxy at `size:800:0` direct | 94,250 bytes |
| `POST /__purge?host=poc.test` | `purged poc.test version 0 -> 1`, then `1 -> 2` |
| imgproxy reachability | `127.0.0.1:8090` returns 200, LAN address refuses |
| `openresty -t` | `syntax is ok` / `test is successful` |

## The one unproven path

**The cache has never served a `HIT`.** Nothing about it has failed — the safety
rules are all proven above — but store-and-return has never been exercised,
because the only origin available to point at is Streamlit, which correctly sends
`cache-control: no-cache`. Overriding that with `proxy_ignore_headers` would make
the test pass by caching Streamlit session state, which is a bug, not a
demonstration.

Closing it needs a cacheable origin: a WordPress site, or
`goodshepherdinsights.com` (own Cloudflare account, so no DNS authority problem —
just a tunnel ingress rule).

Do not confuse untested with broken. A real defect that was found and fixed: the
purge endpoint used to 500 on every call.

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
- **`lua_shared_dict` cannot share a `keys_zone` name.** nginx treats them as the
  same shared memory zone and crash-loops the container. This is what broke
  `/__purge`; see the Purge section.
- **imgproxy with no keys is an open image proxy.** Every `/unsafe/` URL is valid
  to anyone who can reach the port. It must bind to `127.0.0.1`, not `0.0.0.0`.
- **This box has no `docker compose` plugin** (`docker: unknown command`). The
  `docker run` commands above are the working recipe; `docker-compose.yml` is
  documentation of the same two containers, not something executable here.
- **Ports already taken on this host:** 8080 (not 8090 as first assumed),
  8610 (ua-switch), 3001, 5002, 8501-8504.

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
   **Not needed for goodshepherdinsights.com** — own Cloudflare account already.
2. Cache policy must respect `Set-Cookie` and bypass `wp-admin`, `wp-login`,
   `/wp-content/uploads`, `/wp-content/plugins`. Done and asserted.
3. Per-customer purge — done, `POST /__purge?host=`, loopback only.
4. Sign imgproxy URLs once keys are configured; `unsafe` is acceptable only while
   imgproxy is bound to loopback, which it is.
5. Contractual footer credit, opt-out-able, never injected where the customer
   cannot see it. **Deliberately not implemented** — an injected footer is the
   sitewide-links pattern. If a customer pays for the credit it belongs in their
   own theme, not in this proxy.
6. Open, not blocking a first customer: TLS terminates at Cloudflare today (this
   codebase does not terminate TLS); no rate limiting (200 concurrent requests
   all returned 200); no alerting if a container dies.

## Open question for whoever picks this up

goodshepherdinsights.com resolves differently for apex (`216.24.57.1`) and `www`
(`172.67.172.210`, Cloudflare). Decide whether the proxy goes in front of the
apex, `www`, or both before wiring the ingress rule.

## renderready note

`lukapozega/renderready` is the crawler path. It is small: 3 stars, 45 npm
downloads/month, MIT, v1.0.0, created 2026-08-06. It works and runs in production
on this box. Pin the version and mirror it internally.

`removeScriptTags` defaults to `true`, so its output is for crawlers only. Never
serve it to humans.