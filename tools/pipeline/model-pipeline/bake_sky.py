"""
bake_sky.py — 把原始天空球烘焙成 equirectangular 全景图

用法：
    blender -b -P bake_sky.py -- [选项]

选项：
    --src <dir>      默认 F:/godot/model/ek/axo/stage
    --dst <dir>      默认 F:/godot/ga-rts/assets/sky
    --only <names>   只处理指定天空，逗号分隔（如 si_sbg_0110）
    --width <n>      全景图宽度，默认 2048（高度取一半）
    --samples <n>    EEVEE 采样数，默认 32
    --keep-temp      保留逐层中间图（调试用）

## 为什么必须逐层渲染 + 相加

原引擎的天空是**加法混合**的多层球壳：黑色 = 透明，亮处叠加变亮。
证据：si_sun 的贴图是带黑色边角的光晕方块，si_sbg_0100/0102 是纯黑底。

一次性不透明渲染会得到两个错误结果：
1. 太阳变成带黑边的方块
2. 纯白的 si_abg_0000（16x16，平均色 1,1,1）铺满整个天球，把天空糊成灰白

另一个坑：Blender 默认视图变换是 **AgX**，会把 (1,1,1) 压成约 0.75 的灰。
烘焙贴图必须用 **Standard**，否则颜色全部错位。

## 图层取舍

- **跳过 `si_abg_*`**：16x16 纯白，原意应是"环境底色/雾色"，不是可见图层。
  它只有在乘以关卡配置的低强度时才合理，我们没有那份配置，直接跳过。
- 其余层（si_sbg 星空 / si_sbs 星云 / si_sbo 云 / si_sor 轨道环 / si_sun 太阳）全部参与相加。

## 色彩流程

逐层渲染 PNG（Standard 变换，线性→sRGB 由 Blender 完成）
-> 读回时 Blender 自动 sRGB→线性，得到线性值
-> 线性空间相加、钳位
-> 手工线性→sRGB 编码
-> 以 Non-Color 写出，避免二次转换
"""

import bpy
import sys
import json
import math
import argparse
from pathlib import Path
from mathutils import Vector

import numpy as np

SKIP_PREFIXES = ("si_abg",)


def log(m):
    print(f"[sky] {m}", flush=True)


def clean():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_render(width, samples, engine):
    sc = bpy.context.scene
    sc.render.resolution_x = width
    sc.render.resolution_y = width // 2
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"

    # 关键：贴图烘焙不能用 AgX / Filmic，必须 Standard，否则颜色被色调映射改掉
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    sc.view_settings.exposure = 0.0
    sc.view_settings.gamma = 1.0

    world = bpy.data.worlds.new("SkyWorld")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.0, 0.0, 0.0, 1.0)
    bg.inputs[1].default_value = 0.0
    sc.world = world

    if engine == "cycles":
        # 纯自发光场景，Cycles 只需 0 次反弹，不打灯，确定性最高
        sc.render.engine = "CYCLES"
        sc.cycles.device = "CPU"
        sc.cycles.samples = samples
        sc.cycles.use_denoising = False
        sc.cycles.max_bounces = 0
        sc.cycles.diffuse_bounces = 0
        sc.cycles.glossy_bounces = 0
        sc.cycles.transmission_bounces = 0
        sc.cycles.transparent_max_bounces = 0
        sc.cycles.use_adaptive_sampling = False
    else:
        sc.render.engine = "BLENDER_EEVEE_NEXT"
        try:
            sc.eevee.taa_render_samples = samples
        except Exception:
            pass
        for attr in ("use_bloom", "use_ssr", "use_gtao"):
            try:
                setattr(sc.eevee, attr, False)
            except Exception:
                pass


def texture_of(slot_material):
    m = slot_material
    if m is None or not m.use_nodes:
        return None
    for n in m.node_tree.nodes:
        if n.type == "TEX_IMAGE" and n.image is not None:
            return n.image
    return None


def make_emission(img, cache):
    key = img.filepath
    if key in cache:
        return cache[key]

    name = f"SKY_{Path(img.filepath).stem}"
    if name in bpy.data.materials:
        cache[key] = bpy.data.materials[name]
        return bpy.data.materials[name]

    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (400, 0)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (100, 0)
    bsdf.inputs["Base Color"].default_value = (0, 0, 0, 1)
    if "Emission Color" in bsdf.inputs:
        bsdf.inputs["Emission Color"].default_value = (1, 1, 1, 1)
    if "Emission Strength" in bsdf.inputs:
        bsdf.inputs["Emission Strength"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = 1.0
    try:
        bsdf.inputs["Specular IOR Level"].default_value = 0.0
    except Exception:
        pass

    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.location = (-260, 0)
    tex.image = img
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])

    # 必须把 BSDF 接到 Material Output，否则节点树没有输出，渲染结果是纯黑
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    cache[key] = m
    return m


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
    radius = max(maxs[i] - mins[i] for i in range(3)) / 2
    return center, radius


def lin_to_srgb(a):
    a = np.clip(a, 0.0, 1.0)
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1.0 / 2.4) - 0.055)


def read_png_linear(path):
    """读回 PNG。Blender 对 sRGB 图像会自动转成线性值返回。"""
    img = bpy.data.images.load(str(path), check_existing=False)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    arr = px.reshape(h, w, 4)[:, :, :3].copy()
    bpy.data.images.remove(img)
    return arr


def write_png_srgb(arr, path, w, h):
    """arr 是线性 RGB；手工编码成 sRGB 后以 Non-Color 写出，避免二次转换。"""
    srgb = lin_to_srgb(arr)
    out = bpy.data.images.new(path.stem, width=w, height=h, alpha=False, float_buffer=False)
    out.colorspace_settings.name = "Non-Color"
    flat = np.ones((h, w, 4), dtype=np.float32)
    flat[:, :, :3] = srgb
    out.pixels.foreach_set(flat.reshape(-1))
    out.filepath_raw = str(path)
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)


def bake_one(sbg_dir: Path, dst: Path, width: int, samples: int, keep_temp: bool,
             engine: str, blend: str):
    name = sbg_dir.name
    obj_file = sbg_dir / f"{name}.obj"
    if not obj_file.exists():
        cands = list(sbg_dir.glob("*.obj"))
        if not cands:
            log(f"!! {name} 没有 obj，跳过")
            return None
        obj_file = cands[0]

    log("=" * 60)
    log(f"{name}  <- {obj_file.name}")

    clean()
    setup_render(width, samples, engine)
    bpy.ops.wm.obj_import(
        filepath=str(obj_file),
        forward_axis="NEGATIVE_Z",
        up_axis="Y",
        use_split_objects=True,
        use_split_groups=False,
    )

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        log(f"!! {name} 没导入到网格")
        return None

    # 逐对象换自发光材质，并筛掉不参与的层
    cache = {}
    layers = []
    skipped = []
    for o in meshes:
        img = None
        for slot in o.material_slots:
            img = texture_of(slot.material)
            if img:
                break
        if img is None:
            skipped.append((o.name, "<无贴图>"))
            continue
        stem = Path(img.filepath).stem
        if any(stem.startswith(p) for p in SKIP_PREFIXES):
            skipped.append((o.name, stem))
            continue
        mat = make_emission(img, cache)
        o.data.materials.clear()
        o.data.materials.append(mat)
        layers.append((o, stem))

    if not layers:
        log(f"!! {name} 没有任何可用图层")
        return None

    center, radius = scene_bounds()
    log(f"球心 {tuple(round(v,1) for v in center)}  半径 {radius:,.0f}")
    log(f"参与 {len(layers)} 层，跳过 {len(skipped)} 层"
        + (f"：{', '.join(s for _, s in skipped)}" if skipped else ""))

    cam_data = bpy.data.cameras.new("SkyCam")
    cam_data.type = "PANO"
    cam_data.panorama_type = "EQUIRECTANGULAR"
    cam_data.clip_start = 1.0
    cam_data.clip_end = radius * 4.0 + 1000.0
    cam = bpy.data.objects.new("SkyCam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = center
    cam.rotation_euler = (math.radians(90.0), 0.0, 0.0)
    bpy.context.scene.camera = cam

    w, h = width, width // 2
    tmp_dir = dst / "_tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    acc = np.zeros((h, w, 3), dtype=np.float32)

    for idx, (o, stem) in enumerate(layers):
        # 关键：必须遍历「全部网格」而不是只遍历 layers。
        # 被跳过的层（如 si_abg）保留着原始漫反射材质，无灯光下会渲染成不透明黑球，
        # 把里面所有层全部遮挡。只隐 layers 会让所有输出变成纯黑。
        for other in meshes:
            other.hide_render = (other is not o)
        tmp_png = tmp_dir / f"{name}_L{idx:02d}_{stem}.png"
        bpy.context.scene.render.filepath = str(tmp_png.resolve())
        bpy.ops.render.render(write_still=True)
        if not tmp_png.exists():
            log(f"  !! 第 {idx} 层 {stem} 渲染失败")
            continue
        layer = read_png_linear(tmp_png)
        if blend == "sum":
            acc += layer
        elif blend == "max":
            np.maximum(acc, layer, out=acc)
        else:  # screen：a + b - a*b，加法但不会溢出
            acc = acc + layer - acc * layer
        if not keep_temp:
            tmp_png.unlink()
        log(f"  层 {idx:02d} {stem:<24} 累计峰值 {float(acc.max()):.3f}")

    for o in meshes:
        o.hide_render = False

    np.clip(acc, 0.0, 1.0, out=acc)
    out_path = (dst / f"{name}.png").resolve()
    write_png_srgb(acc, out_path, w, h)

    if not keep_temp:
        try:
            tmp_dir.rmdir()
        except Exception:
            pass

    if not out_path.exists():
        log(f"!! 输出失败 {out_path}")
        return None

    log(f"  输出 {out_path.name}  {out_path.stat().st_size/1024:.1f} KB  {w}x{h}")
    return {
        "name": name,
        "source": str(sbg_dir),
        "output": str(out_path),
        "width": w,
        "height": h,
        "layers_used": [s for _, s in layers],
        "layers_skipped": [s for _, s in skipped],
        "sphere_radius": round(radius, 1),
        "bytes": out_path.stat().st_size,
    }


def collect(src: Path, only=None):
    seen = {}
    for stage in sorted(src.iterdir()):
        if not stage.is_dir():
            continue
        for sbg in sorted(stage.iterdir()):
            if not sbg.is_dir() or not sbg.name.startswith("si_sbg"):
                continue
            if only and sbg.name not in only:
                continue
            if sbg.name in seen:
                continue
            seen[sbg.name] = sbg
    return seen


def main():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []

    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="F:/godot/model/ek/axo/stage")
    ap.add_argument("--dst", default="F:/godot/ga-rts/assets/sky")
    ap.add_argument("--only", default=None)
    ap.add_argument("--width", type=int, default=2048)
    ap.add_argument("--samples", type=int, default=16)
    ap.add_argument("--engine", choices=("cycles", "eevee"), default="cycles")
    ap.add_argument("--blend", choices=("screen", "sum", "max"), default="screen",
                    help="层叠加方式。screen=加法但不溢出（默认），sum=纯加法会过曝，max=取最亮")
    ap.add_argument("--keep-temp", action="store_true")
    args = ap.parse_args(argv)

    src = Path(args.src)
    dst = Path(args.dst).resolve()
    only = [s.strip() for s in args.only.split(",")] if args.only else None

    skies = collect(src, only)
    log(f"共 {len(skies)} 个不重复天空")

    results = []
    for name, d in sorted(skies.items()):
        try:
            r = bake_one(d, dst, args.width, args.samples, args.keep_temp, args.engine, args.blend)
        except Exception as e:
            log(f"!! {name} 失败: {e}")
            import traceback
            traceback.print_exc()
            continue
        if r:
            results.append(r)

    manifest = dst / "sky_manifest.json"
    manifest.write_text(
        json.dumps({"version": 3, "blend": f"{args.blend}-linear", "engine": args.engine,
                    "entries": results},
                   ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    log(f"清单 {manifest}")
    log(f"完成 {len(results)} / {len(skies)}")


if __name__ == "__main__":
    main()
