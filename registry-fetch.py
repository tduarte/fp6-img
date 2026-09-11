#!/usr/bin/env python3
"""Fetch the newest published versions of our registry packages, verified.

    registry-fetch.py <registry-url> <trusted-key.rsa.pub> <dest-dir> <group>...

<registry-url> is the Alpine repository root the phones carry in
/etc/apk/repositories (.../alpine/edge/fp6); <trusted-key.rsa.pub> is the key
they carry in /etc/apk/keys (aports/device/catcrafts-fp6-repo/); a <group> is
a comma-separated list of package names whose FIRST member decides the
version: "imsd,imsd-systemd" fetches the newest imsd and the imsd-systemd of
that same version, and fails if the registry lacks it.

Verification mirrors apk's own, so the image trusts exactly what an installed
phone trusts: the index signature (.SIGN.RSA*.<key>, over the index's
compressed tar) against the trusted key, and the signing key's NAME against
the trusted key's; each package's control segment against the index's C:
checksum ("Q1" + base64 sha1); each data segment against the control
segment's datahash (sha256). A package that fails any step is not written.
Prints one "name version sha256" line per apk and writes the same lines to
<dest-dir>/manifest.

Version order: apk's rules for the shapes our own packages use
(X.Y.Z[-rN], numeric components); a suffix like _git is compared as text.
"""
import base64
import gzip
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import zlib

DIGEST = {"RSA": "sha1", "RSA256": "sha256", "RSA512": "sha512"}


def die(msg):
    sys.exit(f"registry-fetch: {msg}")


def gzip_members(data):
    off = 0
    while off < len(data):
        d = zlib.decompressobj(31)
        d.decompress(data[off:])
        end = len(data) - len(d.unused_data)
        if end <= off:
            raise ValueError("gzip stream did not advance")
        yield data[off:end]
        off = end


def tar_files(tar):
    """(name, bytes) for each regular file in a tar image; pax headers skipped."""
    off = 0
    while off + 512 <= len(tar):
        hdr = tar[off:off + 512]
        if hdr == b"\0" * 512:
            return
        size = int(hdr[124:136].split(b"\0")[0].strip() or b"0", 8)
        name = hdr[:100].rstrip(b"\0").decode()
        if hdr[156:157] not in (b"x", b"g"):
            yield name, tar[off + 512:off + 512 + size]
        off += 512 + (size + 511) // 512 * 512


def fetch(url):
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001 - any transport failure retries
            last = e
            time.sleep(10)
    die(f"cannot fetch {url}: {last}")


def verify_index(index_tgz, keyfile):
    """Returns the APKINDEX text after checking the signature against keyfile."""
    try:
        members = list(gzip_members(index_tgz))
    except (zlib.error, ValueError) as e:
        die(f"index: corrupt gzip stream ({e})")
    if len(members) != 2:
        die(f"index: expected 2 gzip streams, found {len(members)}")
    sig_entries = list(tar_files(gzip.decompress(members[0])))
    if not sig_entries:
        die("index: no signature entry")
    name, sig = sig_entries[0]
    m = re.fullmatch(r"\.SIGN\.(RSA\d*)\.(.+)", name)
    if not m or m.group(1) not in DIGEST:
        die(f"index: unexpected signature entry {name!r}")
    kind, signer = m.groups()
    if signer != os.path.basename(keyfile):
        die(f"index: signed by {signer!r}, phones trust {os.path.basename(keyfile)!r}")
    with tempfile.TemporaryDirectory() as t:
        sigf, dataf = os.path.join(t, "sig"), os.path.join(t, "data")
        open(sigf, "wb").write(sig)
        open(dataf, "wb").write(members[1])
        r = subprocess.run(["openssl", "dgst", f"-{DIGEST[kind]}", "-verify", keyfile,
                            "-signature", sigf, dataf], capture_output=True, text=True)
    if r.returncode != 0 or "Verified OK" not in r.stdout:
        die(f"index: signature does NOT verify against {keyfile}: {r.stdout.strip()} {r.stderr.strip()}")
    files = dict(tar_files(gzip.decompress(members[1])))
    if "APKINDEX" not in files:
        die("index: no APKINDEX entry")
    return files["APKINDEX"].decode()


def parse_index(text):
    """{name: {version: fields}} for aarch64 entries."""
    out = {}
    for block in text.split("\n\n"):
        f = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        if f.get("A", "aarch64") != "aarch64" or "P" not in f or "V" not in f:
            continue
        out.setdefault(f["P"], {})[f["V"]] = f
    return out


def version_key(v):
    ver, _, rel = v.partition("-r")
    parts = tuple((0, int(t)) if t.isdigit() else (1, t) for t in re.split(r"[._]", ver))
    return parts, int(rel) if rel.isdigit() else 0


def verify_apk(blob, fields, name):
    try:
        members = list(gzip_members(blob))
    except (zlib.error, ValueError) as e:
        die(f"{name}: corrupt gzip stream ({e})")
    if len(members) != 3:
        die(f"{name}: expected 3 gzip streams, found {len(members)}")
    want = fields.get("C", "")
    if not want.startswith("Q1"):
        die(f"{name}: index has no Q1 checksum")
    got = "Q1" + base64.b64encode(hashlib.sha1(members[1]).digest()).decode()
    if got != want:
        die(f"{name}: control checksum {got} != index {want}")
    pkginfo = dict(tar_files(gzip.decompress(members[1]))).get(".PKGINFO", b"").decode()
    datahash = next((l.split("=", 1)[1].strip() for l in pkginfo.splitlines()
                     if l.startswith("datahash")), None)
    if not datahash:
        die(f"{name}: .PKGINFO has no datahash")
    if hashlib.sha256(members[2]).hexdigest() != datahash:
        die(f"{name}: data segment does not match its datahash")
    if "S" in fields and int(fields["S"]) != len(blob):
        die(f"{name}: size {len(blob)} != index {fields['S']}")


def main(registry, keyfile, dest, groups):
    registry = registry.rstrip("/")
    if not os.path.isfile(keyfile):
        die(f"trusted key {keyfile} not found")
    os.makedirs(dest, exist_ok=True)
    index = parse_index(verify_index(fetch(f"{registry}/aarch64/APKINDEX.tar.gz"), keyfile))
    lines = []
    for group in groups:
        names = group.split(",")
        anchor = names[0]
        if anchor not in index:
            die(f"{anchor}: not in the registry index")
        version = max(index[anchor], key=version_key)
        for n in names:
            fields = index.get(n, {}).get(version)
            if fields is None:
                die(f"{n}-{version}: not in the registry (newest {anchor} is {version})")
            fname = f"{n}-{version}.apk"
            blob = fetch(f"{registry}/aarch64/{fname}")
            verify_apk(blob, fields, fname)
            open(os.path.join(dest, fname), "wb").write(blob)
            lines.append(f"{n} {version} {hashlib.sha256(blob).hexdigest()}")
    with open(os.path.join(dest, "manifest"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
