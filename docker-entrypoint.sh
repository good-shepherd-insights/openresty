#!/bin/sh
# The stock openresty alpine image ships no /tmp/nginx-cache, and proxy_cache_path
# only creates the levels/ subtree, not the parent. Create it before exec.
set -e
mkdir -p /tmp/nginx-cache
exec openresty "$@"