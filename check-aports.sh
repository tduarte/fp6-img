#!/bin/sh -eu
# check-aports.sh - verify the committed sha512sums of every aport's LOCAL
# source files (scripts, units, configs, patches) against the files actually
# in the aport directory.
#
# Why this exists: CI run 52 (2026-09-05) died after 57 minutes, at the point
# abuild reached fp6-vendor-blobs, because the extractor had been changed and
# its sha512sum had not. abuild finds that only when it gets to that aport;
# this finds it in under a second, before pmbootstrap does anything. build.sh
# runs it first; run it by hand before pushing too.
#
# Out of scope, by design: sources fetched from a URL (abuild verifies those
# against the same sums after fetching), and the aports whose sums build.sh
# regenerates at build time with 'pmbootstrap checksum' (their tarballs are
# generated there and do not exist here) - that list is read from build.sh so
# the two cannot drift apart.
cd "$(dirname "$0")"
regen=$(sed -n 's/^pmbootstrap checksum \([a-z0-9-]*\)$/\1/p' build.sh | tr '\n' ' ')
rc=0
for d in aports/*/*/; do
	[ -f "$d/APKBUILD" ] || continue
	d=${d%/}
	case " $regen " in *" ${d##*/} "*) continue ;; esac
	info=$(cd "$d" && sh -c '. ./APKBUILD; printf "%s\n" $source; printf "==\n"; printf "%s\n" "$sha512sums"' 2>/dev/null) || {
		echo "$d: APKBUILD does not source cleanly" >&2; rc=1; continue
	}
	srcs=$(printf '%s\n' "$info" | sed '/^==$/,$d')
	sums=$(printf '%s\n' "$info" | sed '1,/^==$/d')
	for s in $srcs; do
		case "$s" in
		*://*) continue ;;                 # remote: abuild fetches and verifies
		*::*) f=${s%%::*} ;;
		*) f=${s##*/} ;;
		esac
		# a local source may sit in a subdirectory (rules/00_log_all.nft);
		# the sums entry is keyed by its basename either way
		path="$d/$s"; [ -f "$path" ] || path="$d/$f"
		want=$(printf '%s\n' "$sums" | awk -v f="$f" '$2==f{print $1}')
		[ "$want" = REPLACED_BY_CI ] && continue
		if [ ! -f "$path" ]; then
			echo "$d: local source '$s' is missing" >&2; rc=1; continue
		fi
		if [ -z "$want" ]; then
			echo "$d: '$f' has no sha512sums entry" >&2; rc=1; continue
		fi
		have=$(sha512sum "$path" | awk '{print $1}')
		if [ "$want" != "$have" ]; then
			echo "$d: sha512 MISMATCH for '$f' (APKBUILD has ${want%"${want#????????????????}"}..., file is ${have%"${have#????????????????}"}...)" >&2
			echo "$d:   fix: update the sha512sums entry to: $have  $f" >&2
			rc=1
		fi
	done
done
[ "$rc" = 0 ] && echo "check-aports: all local source checksums match"
exit $rc
