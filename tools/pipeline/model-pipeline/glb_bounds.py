"""读取舰队 GLB 的包围盒尺寸（迁移映射用，临时工具）。

只读 accessor 的 min/max —— 不套节点变换。先用已知机型校准：
ou05 船长应约 63.6 m、ou134 约 351.7 m（content/units/*/unit.tbl 里记的数）。
若这两个对得上，说明管线导出时已把变换烘焙进顶点，本工具的数值可直接用。
"""

import glob
import json
import os
import struct
import sys

JSON_CHUNK = 0x4E4F534A


def read_json_chunk(path):
    with open(path, "rb") as handle:
        data = handle.read()
    magic, _version, _length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        return None
    offset = 12
    while offset < len(data):
        chunk_len, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        chunk = data[offset : offset + chunk_len]
        offset += chunk_len
        if chunk_type == JSON_CHUNK:
            return json.loads(chunk.decode("utf-8"))
    return None


def bounds(path):
    doc = read_json_chunk(path)
    if doc is None:
        return None
    lo = [1e30, 1e30, 1e30]
    hi = [-1e30, -1e30, -1e30]
    found = False
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            index = prim.get("attributes", {}).get("POSITION")
            if index is None:
                continue
            accessor = doc["accessors"][index]
            amin, amax = accessor.get("min"), accessor.get("max")
            if not amin or not amax:
                continue
            found = True
            for axis in range(3):
                lo[axis] = min(lo[axis], amin[axis])
                hi[axis] = max(hi[axis], amax[axis])
    if not found:
        return None
    return lo, hi


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "assets/models/ships"
    rows = []
    for path in sorted(glob.glob(os.path.join(root, "**", "*.glb"), recursive=True)):
        box = bounds(path)
        name = os.path.splitext(os.path.basename(path))[0]
        if box is None:
            rows.append((name, None, None, None, None))
            continue
        lo, hi = box
        size = [hi[i] - lo[i] for i in range(3)]
        rows.append((name, size[0], size[1], size[2], max(size)))

    rows.sort(key=lambda r: (r[4] is None, r[4] if r[4] else 0))
    print(f"{'model':<10} {'X(宽)':>9} {'Y(高)':>9} {'Z(长)':>9} {'最长边':>9} {'建议radius':>10}")
    for name, sx, sy, sz, longest in rows:
        if sx is None:
            print(f"{name:<10} {'读取失败':>9}")
            continue
        print(f"{name:<10} {sx:9.2f} {sy:9.2f} {sz:9.2f} {longest:9.2f} {longest/2:10.2f}")


if __name__ == "__main__":
    main()
