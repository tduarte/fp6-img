#!/usr/bin/env python3
"""Re-sign an apk (v2 format) with another RSA key, in place.

    apk-resign.py <pkg.apk> <private key .rsa> <public key file name>

An apk is three concatenated gzip streams: the signature tar, the control
tar (.PKGINFO) and the data tar. The signature covers the control stream
only, so replacing the first stream re-signs the package while its identity
checksum (over the control stream) and its contents stay byte-identical.
This is what abuild-sign does to the control segment when abuild packages.
"""
import gzip
import io
import os
import subprocess
import sys
import tarfile
import zlib

DIGEST = {"RSA": "sha1", "RSA256": "sha256", "RSA512": "sha512"}


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


def first_entry_name(tar):
    """Name of the first regular file in a tar stream, skipping pax headers."""
    off = 0
    while off + 512 <= len(tar):
        hdr = tar[off:off + 512]
        size = int(hdr[124:136].split(b"\0")[0].strip() or b"0", 8)
        if hdr[156:157] not in (b"x", b"g"):  # not a pax extended/global header
            return hdr[:100].rstrip(b"\0").decode()
        off += 512 + (size + 511) // 512 * 512
    raise ValueError("no file entry in signature tar")


def main(path, privkey, pubname):
    members = list(gzip_members(open(path, "rb").read()))
    if len(members) != 3:
        sys.exit(f"{path}: expected 3 gzip streams, found {len(members)}")
    old_sig, control, payload = members
    # keep the original digest type: the entry is .SIGN.<RSA|RSA256|RSA512>.<key>
    name = first_entry_name(gzip.decompress(old_sig))
    kind = name.split(".")[2] if name.startswith(".SIGN.") else ""
    if kind not in DIGEST:
        sys.exit(f"{path}: unexpected signature entry {name!r}")
    if not os.access(privkey, os.R_OK):
        sys.exit(f"{privkey}: not readable by uid {os.getuid()} (pmbootstrap's "
                 "abuild-keygen runs as the chroot user, uid 12345, and leaves "
                 "the key 0600 to it - sign from a readable copy)")
    try:
        sig = subprocess.run(
            ["openssl", "dgst", f"-{DIGEST[kind]}", "-sign", privkey],
            input=control, stdout=subprocess.PIPE, check=True,
        ).stdout
    except subprocess.CalledProcessError as e:
        sys.exit(f"openssl dgst -sign exited {e.returncode} signing {path}")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        info = tarfile.TarInfo(f".SIGN.{kind}.{pubname}")
        info.size = len(sig)
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(sig))
    # like abuild-tar --cut: header + data blocks, no end-of-archive marker
    cut = 512 + (len(sig) + 511) // 512 * 512
    new_sig = gzip.compress(buf.getvalue()[:cut], mtime=0)
    with open(path, "wb") as f:
        f.write(new_sig + control + payload)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
