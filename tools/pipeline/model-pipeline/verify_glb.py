"""
verify_glb.py — 回读校验导出的 GLB：层级、朝向、尺寸、炮塔 pivot

用法：
    blender -b -P verify_glb.py -- <glb 路径> [...]

检查项：
    1. 层级结构（根节点 + body + turret_*）
    2. 世界包围盒尺寸（应与 manifest 记录一致）
    3. 炮塔 pivot 是否落在自身包围盒中心（误差应接近 0）
    4. glTF 前向语义：舰首应在 -Z（与 Godot 一致）
    5. 材质数量与贴图（应无重复材质）
"""

import bpy
import sys
import math
from pathlib import Path
from mathutils import Vector


def log(m):
    print(f"[verify] {m}", flush=True)


def clean():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def world_bbox(obj):
    mins = [math.inf] * 3
    maxs = [-math.inf] * 3
    for c in obj.bound_box:
        v = obj.matrix_world @ Vector(c)
        for i in range(3):
            mins[i] = min(mins[i], v[i])
            maxs[i] = max(maxs[i], v[i])
    return mins, maxs


def size_to_gltf(v):
    """Blender 尺寸 -> glTF/Godot 尺寸。轴交换 (bx,by,bz) -> (bx,bz,by)。
    尺寸永远为正，不能像位置那样取负（Blender Z 上 / -Y 前 -> glTF Y 上 / -Z 前）。"""
    return (v[0], v[2], v[1])


def verify(path: Path):
    log("=" * 70)
    log(f"文件 {path.name}  ({path.stat().st_size / 1024:.1f} KB)")

    clean()
    bpy.ops.import_scene.gltf(filepath=str(path))

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    roots = [o for o in bpy.context.scene.objects if o.parent is None]
    log(f"根节点: {[o.name for o in roots]}")
    log(f"网格节点: {len(meshes)}")

    total_tris = 0
    for o in meshes:
        tris = sum(max(0, len(p.vertices) - 2) for p in o.data.polygons)
        total_tris += tris
        mins, maxs = world_bbox(o)
        size = [round(maxs[i] - mins[i], 2) for i in range(3)]
        mats = [s.material.name if s.material else "<none>" for s in o.material_slots]

        # 原点（局部 0,0,0）在世界中的位置，与自身包围盒中心比较
        origin_w = o.matrix_world.translation
        center_w = Vector([(mins[i] + maxs[i]) / 2 for i in range(3)])
        pivot_err = (origin_w - center_w).length

        log(f"  [{o.name}]")
        log(f"    Blender 尺寸  X={size[0]:>10}  Y={size[1]:>10}  Z={size[2]:>10}")
        g = size_to_gltf(size)
        log(f"    Godot  尺寸  X={g[0]:>10}  Y={g[1]:>10}  Z={g[2]:>10}   (Y=上, Z=前后)")
        log(f"    三角面 {tris}, 材质 {len(o.material_slots)}: {mats}")
        log(f"    原点 {tuple(round(v,2) for v in origin_w)}  盒中心 {tuple(round(v,2) for v in center_w)}")
        if o.name.startswith("turret"):
            flag = "OK" if pivot_err < 0.01 else f"偏差 {pivot_err:.3f}"
            log(f"    炮塔 pivot 校验: {flag}")
        else:
            log(f"    pivot 偏离盒中心 {pivot_err:.2f}（本体允许，模型自身原点）")

    log(f"  合计三角面 {total_tris}")

    # 全体包围盒（父级变换已含在内）
    mins = [math.inf] * 3
    maxs = [-math.inf] * 3
    for o in meshes:
        a, b = world_bbox(o)
        for i in range(3):
            mins[i] = min(mins[i], a[i])
            maxs[i] = max(maxs[i], b[i])
    total = [round(maxs[i] - mins[i], 2) for i in range(3)]
    log(f"  Blender 全体尺寸 X={total[0]} Y={total[1]} Z={total[2]}")
    g = size_to_gltf(total)
    log(f"  Godot   全体尺寸 X={g[0]} Y={g[1]} Z={g[2]}")
    longest = max(range(3), key=lambda i: g[i])
    axis = "XYZ"[longest]
    verdict = "OK（舰体长轴在 Z，符合 Godot 前后向）" if axis == "Z" else f"异常：最长轴是 {axis}"
    log(f"  长轴校验 = {axis}  {verdict}")
    log(f"  注意：舰首朝 +Z 还是 -Z 无法自动判定，需目视确认（Godot 前向为 -Z）")

    # 材质去重检查
    all_mats = set()
    for o in meshes:
        for s in o.material_slots:
            if s.material:
                all_mats.add(s.material.name)
    log(f"  去重后材质共 {len(all_mats)} 个: {sorted(all_mats)}")


def main():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    if not argv:
        log("用法: blender -b -P verify_glb.py -- <glb> [...]")
        return
    for a in argv:
        p = Path(a)
        if not p.exists():
            log(f"!! 不存在 {p}")
            continue
        try:
            verify(p)
        except Exception as e:
            log(f"!! 校验失败 {p.name}: {e}")
            import traceback
            traceback.print_exc()


if __name__ == "__main__":
    main()
