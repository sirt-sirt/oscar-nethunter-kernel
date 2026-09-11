#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Read-only EROFS inspector for oscar's vendor_dlkm image.

    verify-erofs.py dump   <image>
    verify-erofs.py assert <image> <partition-size> <manifest>
    verify-erofs.py check  <image> <staging-dir> <partition-size>

Why this is hand-rolled: the GitHub runner can create an erofs image but has no
way to look inside one. There is no loop mount in the container and no fuse, so
"it built without an error" is the only feedback mkfs.erofs gives, and that is
not enough to bet a phone on. This parses the finished image the same way the
kernel does and fails the build before a zip is ever produced.

It reads uncompressed inodes only. Compressed file CONTENT is never decoded,
which is fine: the modules are vermagic-checked before they are packed, and
what has to be proven here is structural - the right files, the right sizes,
the right SELinux labels, the right total size.

The SELinux part is the subtle one. Labels are stored as extended attributes,
and erofs keeps xattrs that repeat across many inodes in a shared table rather
than inline. On the stock image all 52 labels are shared, so a parser that only
walks inline entries reports every file as unlabelled - which is exactly the
wrong answer, and exactly the mistake this code was written to stop repeating.
Both encodings are handled below.
"""

import os
import struct
import sys

EROFS_MAGIC = 0xE0F5E1E2

# erofs_inode_compact / _extended, i_format bit 0 selects which.
LAYOUT_NAMES = {
    0: "FLAT_PLAIN",
    1: "COMPRESSION_LEGACY",
    2: "FLAT_INLINE",
    3: "CHUNK_BASED",
    4: "COMPRESSION",
}

# xattr name indices, from include/erofs_fs.h. 6 is "security.".
XATTR_PREFIX = {1: "user.", 2: "system.posix_acl_access",
                3: "system.posix_acl_default", 4: "trusted.",
                6: "security.", 7: "system."}

EXPECTED_META = [
    "/etc",
    "/etc/build.prop",
    "/etc/fs_config_dirs",
    "/etc/fs_config_files",
    "/lib",
    "/lib/modules",
    "/lib/modules/modules.alias",
    "/lib/modules/modules.blocklist",
    "/lib/modules/modules.dep",
    "/lib/modules/modules.load",
    "/lib/modules/modules.softdep",
]

VENDOR_FILE = "u:object_r:vendor_file:s0"
VENDOR_CONFIGS = "u:object_r:vendor_configs_file:s0"


class Erofs(object):
    def __init__(self, path):
        with open(path, "rb") as fh:
            self.d = fh.read()
        self.path = path
        self.filesize = len(self.d)
        d = self.d
        sb = 1024
        if len(d) < sb + 128:
            raise SystemExit("file is too small to be an EROFS image")
        magic, = struct.unpack_from("<I", d, sb)
        if magic != EROFS_MAGIC:
            raise SystemExit("not an EROFS image: magic is 0x%08x" % magic)
        self.feature_compat, = struct.unpack_from("<I", d, sb + 8)
        self.blkszbits = d[sb + 12]
        self.root_nid, = struct.unpack_from("<H", d, sb + 14)
        self.inos, = struct.unpack_from("<Q", d, sb + 16)
        self.build_time, = struct.unpack_from("<Q", d, sb + 24)
        self.blocks, = struct.unpack_from("<I", d, sb + 36)
        self.meta_blkaddr, = struct.unpack_from("<I", d, sb + 40)
        self.xattr_blkaddr, = struct.unpack_from("<I", d, sb + 44)
        self.uuid = d[sb + 48:sb + 64].hex()
        self.volume = d[sb + 64:sb + 80].split(b"\x00")[0].decode("ascii", "replace")
        self.feature_incompat, = struct.unpack_from("<I", d, sb + 80)
        self.BS = 1 << self.blkszbits
        self.nodes = {}
        self._walk(self.root_nid, "", 0)

    def inode(self, nid):
        d = self.d
        off = self.meta_blkaddr * self.BS + nid * 32
        fmt, xcnt = struct.unpack_from("<HH", d, off)
        ver = fmt & 1
        layout = (fmt >> 1) & 7
        if ver == 0:
            (_f, _x, mode, _nlink, size, _r, u, _ino,
             uid, gid, _r2) = struct.unpack_from("<HHHHIIIIHHI", d, off)
            isize = 32
        else:
            (_f, _x, mode, _r, size, u, _ino, uid, gid,
             _ct, _ns, _nlink) = struct.unpack_from("<HHHHQIIIIQII", d, off)
            isize = 64
        xsz = 12 + (xcnt - 1) * 4 if xcnt else 0
        return {"nid": nid, "off": off, "layout": layout, "mode": mode,
                "size": size, "u": u, "uid": uid, "gid": gid,
                "isize": isize, "xsz": xsz, "xcnt": xcnt}

    def data(self, i):
        """Uncompressed inode payload, or None when the inode is compressed."""
        d = self.d
        if i["layout"] == 0:
            return d[i["u"] * self.BS:i["u"] * self.BS + i["size"]]
        if i["layout"] == 2:
            nb = i["size"] // self.BS
            out = d[i["u"] * self.BS:i["u"] * self.BS + nb * self.BS] if nb else b""
            tail = i["size"] % self.BS
            if tail:
                io = i["off"] + i["isize"] + i["xsz"]
                out += d[io:io + tail]
            return out
        return None

    def label(self, i):
        """security.selinux, from the shared xattr table or from inline entries."""
        if not i["xcnt"]:
            return None
        d = self.d
        base = i["off"] + i["isize"]
        shared_count = d[base + 4]
        found = None

        def parse_entry(eoff):
            nlen = d[eoff]
            nidx = d[eoff + 1]
            vsz, = struct.unpack_from("<H", d, eoff + 2)
            name = d[eoff + 4:eoff + 4 + nlen].decode("ascii", "replace")
            val = d[eoff + 4 + nlen:eoff + 4 + nlen + vsz]
            full = XATTR_PREFIX.get(nidx, "") + name
            return full, val, 4 + nlen + vsz

        for k in range(shared_count):
            xid, = struct.unpack_from("<I", d, base + 12 + 4 * k)
            full, val, _ = parse_entry(self.xattr_blkaddr * self.BS + xid * 4)
            if full == "security.selinux":
                found = val.rstrip(b"\x00").decode("ascii", "replace")

        pos = base + 12 + 4 * shared_count
        end = base + i["xsz"]
        while pos + 4 <= end:
            if d[pos] == 0 and d[pos + 1] == 0:
                break
            full, val, used = parse_entry(pos)
            if full == "security.selinux":
                found = val.rstrip(b"\x00").decode("ascii", "replace")
            pos += (used + 3) & ~3
        return found

    def readdir(self, i):
        blob = self.data(i)
        out = []
        if blob is None:
            return out
        pos = 0
        while pos < len(blob):
            blk = blob[pos:pos + self.BS]
            if len(blk) < 12:
                break
            first_nameoff, = struct.unpack_from("<H", blk, 8)
            cnt = first_nameoff // 12
            for k in range(cnt):
                nid, noff, ftype, _pad = struct.unpack_from("<QHBB", blk, k * 12)
                if k + 1 < cnt:
                    nend, = struct.unpack_from("<H", blk, (k + 1) * 12 + 8)
                else:
                    nend = len(blk)
                name = blk[noff:nend].split(b"\x00")[0].decode("utf-8", "replace")
                out.append((name, nid, ftype))
            pos += self.BS
        return out

    def _walk(self, nid, path, depth):
        if depth > 16:
            raise SystemExit("directory nesting deeper than 16 - refusing to recurse")
        for name, cnid, ftype in self.readdir(self.inode(nid)):
            if name in (".", "..", ""):
                continue
            p = path + "/" + name
            i = self.inode(cnid)
            self.nodes[p] = (i, ftype)
            if ftype == 2:
                self._walk(cnid, p, depth + 1)


def print_superblock(fs):
    print("=== superblock ===")
    print("  file size        %d" % fs.filesize)
    print("  blkszbits        %d  (block size %d)" % (fs.blkszbits, fs.BS))
    print("  blocks           %d  (filesystem %d bytes)" % (fs.blocks, fs.blocks * fs.BS))
    print("  root_nid         %d" % fs.root_nid)
    print("  inos             %d" % fs.inos)
    print("  meta_blkaddr     %d" % fs.meta_blkaddr)
    print("  xattr_blkaddr    %d" % fs.xattr_blkaddr)
    print("  feature_compat   0x%x" % fs.feature_compat)
    print("  feature_incompat 0x%x" % fs.feature_incompat)
    print("  uuid             %s" % fs.uuid)
    print("  build_time       %d" % fs.build_time)


def cmd_dump(fs):
    print_superblock(fs)
    print("")
    print("=== %d entries ===" % len(fs.nodes))
    print("%-42s %10s %-6s %-18s %s" % ("path", "size", "mode", "layout", "selinux"))
    layouts = {}
    for p in sorted(fs.nodes):
        i, ftype = fs.nodes[p]
        ln = LAYOUT_NAMES.get(i["layout"], "L%d" % i["layout"])
        layouts[ln] = layouts.get(ln, 0) + 1
        print("%-42s %10d %-6o %-18s %s" % (p, i["size"], i["mode"] & 0o7777, ln,
                                            fs.label(i) or "(none)"))
    print("")
    print("  layouts: %s" % ", ".join("%s=%d" % kv for kv in sorted(layouts.items())))


def expected_paths(manifest):
    mods = []
    with open(manifest, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            mods.append(line)
    paths = set(EXPECTED_META)
    for m in mods:
        paths.add("/lib/modules/%s.ko" % m)
    return paths, mods


def check_labels(fs, fail):
    for p in sorted(fs.nodes):
        i, _ft = fs.nodes[p]
        got = fs.label(i)
        want = VENDOR_CONFIGS if p == "/etc" or p.startswith("/etc/") else VENDOR_FILE
        if got != want:
            fail("%s is labelled %s, expected %s" % (p, got or "(none)", want))
    return True


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mode = sys.argv[1]
    fs = Erofs(sys.argv[2])

    problems = []

    def fail(msg):
        problems.append(msg)
        print("::error::%s" % msg)

    def ok(msg):
        print("  ok      %s" % msg)

    if mode == "dump":
        cmd_dump(fs)
        return 0

    print_superblock(fs)
    print("")

    if fs.blkszbits != 12:
        fail("block size is %d, the phone's kernel expects 4096" % fs.BS)
    else:
        ok("4096-byte blocks")

    # Stock carries feature_incompat 0x1, ZERO_PADDING only. Anything else means
    # a feature this 5.4 kernel's erofs driver cannot read - ztailpacking,
    # fragments and dedupe all landed in erofs-utils 1.5/1.6 and in much later
    # kernels. The mount would simply fail and the phone would not boot.
    if fs.feature_incompat != 0x1:
        fail("feature_incompat is 0x%x, stock is 0x1; a newer on-disk feature "
             "would not mount on Linux 5.4" % fs.feature_incompat)
    else:
        ok("feature_incompat 0x1, same as stock")

    if mode == "assert":
        part = int(sys.argv[3])
        want_paths, mods = expected_paths(sys.argv[4])
        got_paths = set(fs.nodes)

        extra = sorted(got_paths - want_paths)
        absent = sorted(want_paths - got_paths)
        for p in absent:
            fail("missing from the image: %s" % p)
        for p in extra:
            fail("unexpected entry in the image: %s" % p)
        if not extra and not absent:
            ok("exactly %d entries, %d of them modules" % (len(want_paths), len(mods)))

        check_labels(fs, fail)
        if not problems:
            ok("every SELinux label matches the stock partition")

        if fs.filesize != part:
            fail("image is %d bytes, the partition is %d; AnyKernel3 would fall "
                 "into the lptools resize path" % (fs.filesize, part))
        else:
            ok("padded to exactly %d bytes - flash_generic writes it in place" % part)

        if fs.blocks * fs.BS > part:
            fail("the filesystem claims %d bytes, more than the partition holds"
                 % (fs.blocks * fs.BS))

    elif mode == "check":
        stage = sys.argv[3]
        part = int(sys.argv[4])

        on_disk = {}
        for root, _dirs, files in os.walk(stage):
            for f in files:
                full = os.path.join(root, f)
                rel = "/" + os.path.relpath(full, stage).replace(os.sep, "/")
                on_disk[rel] = os.path.getsize(full)

        in_img = {}
        for p, (i, ft) in fs.nodes.items():
            if ft != 2:
                in_img[p] = i["size"]

        for p in sorted(set(on_disk) - set(in_img)):
            fail("staged but not in the image: %s" % p)
        for p in sorted(set(in_img) - set(on_disk)):
            fail("in the image but never staged: %s" % p)
        for p in sorted(set(on_disk) & set(in_img)):
            if on_disk[p] != in_img[p]:
                fail("%s is %d bytes on disk but %d in the image"
                     % (p, on_disk[p], in_img[p]))
        if not problems:
            ok("all %d files round-trip with identical sizes" % len(on_disk))

        before = len(problems)
        check_labels(fs, fail)
        if len(problems) == before:
            ok("every SELinux label matches the stock partition")
        else:
            print("::error::mkfs.erofs accepted --file-contexts but produced no "
                  "labels. Its Ubuntu build is not linked against libselinux; "
                  "build erofs-utils from source with --with-selinux.")

        if fs.filesize != part:
            fail("image is %d bytes, expected exactly %d" % (fs.filesize, part))
        else:
            ok("padded to exactly %d bytes" % part)
    else:
        print("unknown mode: %s" % mode)
        return 2

    print("")
    if problems:
        print("VERDICT: %d problem(s) - this image must not be flashed." % len(problems))
        return 1
    print("VERDICT: the image matches the stock partition's shape. Safe to pack.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
