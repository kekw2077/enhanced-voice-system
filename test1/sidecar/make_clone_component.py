"""Zip the evs_clone onedir, hash the full zip, and split it into <2 GiB parts
(GitHub release assets are capped at 2 GiB). ComponentManager concatenates the
parts back into the identical zip and verifies this sha256."""
import os, zipfile, hashlib

SRC = r"f:\xtts\dist\evs_clone"        # onedir; zip its CONTENTS (root = exe + _internal)
ZIP = r"f:\xtts\evs_clone.zip"
PART = 1900 * 1024 * 1024              # 1900 MiB < 2 GiB GitHub cap

def build():
    with zipfile.ZipFile(ZIP, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=1, allowZip64=True) as z:
        for root, _d, files in os.walk(SRC):
            for f in files:
                full = os.path.join(root, f)
                arc = os.path.relpath(full, SRC)
                # .pth checkpoints are already-compressed containers -> STORE
                # them (deflate wastes minutes for ~0 gain).
                ct = zipfile.ZIP_STORED if f.endswith(".pth") else zipfile.ZIP_DEFLATED
                z.write(full, arc, compress_type=ct)
    return os.path.getsize(ZIP)

def hash_and_split():
    h = hashlib.sha256()
    idx, written = 1, 0
    part = open(ZIP + ".%03d" % idx, "wb")
    with open(ZIP, "rb") as f:
        while True:
            chunk = f.read(8 * 1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
            off = 0
            while off < len(chunk):
                take = min(PART - written, len(chunk) - off)
                part.write(chunk[off:off + take])
                written += take
                off += take
                if written >= PART:
                    part.close()
                    idx += 1
                    written = 0
                    part = open(ZIP + ".%03d" % idx, "wb")
    part.close()
    return h.hexdigest(), idx

sz = build()
print("ZIP_SIZE", sz, flush=True)
sha, parts = hash_and_split()
print("SHA256", sha, flush=True)
print("PARTS", parts, flush=True)
for i in range(1, parts + 1):
    p = ZIP + ".%03d" % i
    print("PART", i, os.path.getsize(p), flush=True)
