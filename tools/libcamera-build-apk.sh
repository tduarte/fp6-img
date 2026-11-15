#!/bin/sh
# Runs inside an aarch64 alpine:edge container. /aport (rw), /out, /distfiles mounted.
set -e
cat > /etc/apk/repositories <<R
http://dl-cdn.alpinelinux.org/alpine/edge/main
http://dl-cdn.alpinelinux.org/alpine/edge/community
http://dl-cdn.alpinelinux.org/alpine/edge/testing
R
apk add -q alpine-sdk
mkdir -p /var/cache/distfiles && cp /distfiles/* /var/cache/distfiles/
ls /root/.config/abuild/*.rsa >/dev/null 2>&1 || abuild-keygen -a -n -q
cp /root/.config/abuild/*.pub /etc/apk/keys/
cd /aport
abuild -F checksum
abuild -F -r -P /out
