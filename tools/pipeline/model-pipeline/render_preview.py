"""
render_preview.py — 正交投影预览渲染，用于目视确认舰首朝向

用法：
    blender -b -P render_preview.py -- <glb> [<glb> ...] [--out <目录>] [--res <边长>]

输出：<目录>/<id>_<view>.png，view 为 side / top / three_quarter

关键：脚本会把每个视角的"屏幕右方向 = 世界哪个轴"打印出来，
      这样看图即可无歧义判断舰首朝向。
"""

import bpy
import sys
import math
import argparse
from pathlib import Path
from mathutils import Vector


def log(m):
    print(f"[render] {m}", flush=True)


def clean():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_render(res):
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x = res
    sc.render.resolution_y = int(res * 0.5625)
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"

    # 世界背景：中灰，避免纯黑看不见轮廓
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.08, 0.09, 0.12, 1.0)
    bg.inputs[1].default_value = 1.0
    sc.world = world

    # 三盏太阳灯，保证任何角度都能看清形状
    for name, rot in (
        ("key", (math.radians(55), 0, math.radians(35))),
        ("fill", (math.radians(120), 0, math.radians(-120))),
        ("rim", (math.radians(-30), 0, math.radians(180))),
    ):
        light = bpy.data.lights.new(name, type="SUN")
        light.energy = 3.0
        obj = bpy.data.objects.new(name, light)
        obj.rotation_euler = rot
        sc.collection.objects.link(obj)


def scene_bounds():
    mins = [math.inf] * 3
    maxs = [-math.inf] * 3
    for o in bpy.context.scene.objects:
        if o.type != "MESH":
            continue
        for c in o.bound_box:
            v = o.matrix_world @ Vector(c)
            for i in range(3):
                mins[i] = min(mins[i], v[i])
                maxs[i] = max(maxs[i], v[i])
    if mins[0] is math.inf:
        return Vector((0, 0, 0)), 1.0
    center = Vector([(mins[i] + maxs[i]) / 2 for i in range(3)])
    size = max(maxs[i] - mins[i] for i in range(3))
    return center, max(size, 0.001)


def make_camera(center, size, direction, up):
    """direction = 相机相对中心的位移方向（会归一化）。返回相机对象。"""
    d = Vector(direction).normalized()
    dist = size * 2.5
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = size * 1.15
    cam_data.clip_start = 0.01
    cam_data.clip_end = dist * 4 + size * 4
    cam = bpy.data.objects.new("Cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = center + d * dist

    # 让相机看向中心
    quat = (center - cam.location).to_track_quat("-Z", "Y")
    cam.rotation_mode = "QUATERNION"
    cam.rotation_quaternion = quat

    bpy.context.scene.camera = cam

    # 计算屏幕右方向（世界坐标）
    fwd = (center - cam.location).normalized()
    upv = (cam.matrix_world.to_3x3() @ Vector((0, 1, 0))).normalized()
    right = fwd.cross(upv).normalized()
    return cam, right


def axis_name(v, eps=0.35):
    """把一个方向向量描述成 -X/+X/-Y/+Y/-Z/+Z"""
    labels = []
    for i, ax in enumerate("XYZ"):
        if v[i] > eps:
            labels.append(f"+{ax}")
        elif v[i] < -eps:
            labels.append(f"-{ax}")
    return "".join(labels) or "斜向"


def render_one(glb: Path, out_dir: Path, res: int):
    log("=" * 60)
    log(f"{glb.name}")

    # 关键：Blender 的 render.filepath 若是相对路径，会相对“进程工作目录”解析，
    # 而不是项根目录（实测会写到 C:\tools\...）。因此这里强制绝对路径。
    out_dir = out_dir.resolve()

    clean()
    setup_render(res)
    bpy.ops.import_scene.gltf(filepath=str(glb))

    center, size = scene_bounds()
    log(f"包围盒中心 {tuple(round(v,2) for v in center)}  最大边长 {size:.2f}")

    out_dir.mkdir(parents=True, exist_ok=True)
    stem = glb.stem

    views = {
        # name: (相机方向, 说明)
        "side":     ((0, 1, 0),       "从 +Y 看（Blender 上方），实际是 Godot 的俯视"),
        "side_x":   ((1, 0, 0),       "从 +X 看，侧面轮廓"),
        "front":    ((0, 0, 1),       "从 +Z 看"),
    }

    for name, (direction, desc) in views.items():
        cam, right = make_camera(center, size, direction, (0, 0, 1))
        log(f"视角 {name:8s} {desc}")
        log(f"          屏幕右方 = {axis_name(right)}   相机在 {axis_name(Vector(direction))} 侧")
        bpy.context.scene.render.filepath = str(out_dir / f"{stem}_{name}.png")
        bpy.ops.render.render(write_still=True)
        bpy.data.objects.remove(cam, do_unlink=True)


def main():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []

    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--out", default="tools/pipeline/model-pipeline/preview")
    ap.add_argument("--res", type=int, default=900)
    args = ap.parse_args(argv)

    out_dir = Path(args.out).resolve()
    for f in args.files:
        p = Path(f)
        if not p.exists():
            log(f"!! 不存在 {p}")
            continue
        try:
            render_one(p, out_dir, args.res)
        except Exception as e:
            log(f"!! {p.name} 渲染失败: {e}")
            import traceback
            traceback.print_exc()

    log(f"输出目录 {out_dir.resolve()}")


if __name__ == "__main__":
    main()
