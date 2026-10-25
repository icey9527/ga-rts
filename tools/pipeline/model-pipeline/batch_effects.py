"""
batch_effects.py — 特效（贴图公告板）OBJ -> GLB 批量转换管线

用法（Blender headless）：
    blender -b -P batch_effects.py -- [选项]

选项：
    --src <dir>       素材根目录，可重复传入多次
                      默认 F:/godot/model/el/scn0  和  F:/godot/model/ek/axo/effects
    --dst <dir>       输出根目录，默认 F:/godot/ga-rts/assets/models/effects
    --only <ids>      只处理指定逻辑 ID，逗号分隔，如 oe0350a,si_eah_0130
    --limit <n>       最多处理 n 个逻辑 ID（冒烟测试用）
    --width <n>       贴图重采样上限（只缩不放），默认 256
    --tex-dir <dir>   生成带 alpha 贴图的落地目录，默认 <本目录>/.effects_tex
    --manifest <path> 清单输出路径，默认 <本目录>/effects_manifest.json
    --no-export       只做测量与报告，不写任何文件

设计依据：
    ADR-0005 模型管线、ADR-0011 工具与游戏代码分离（特效不复用舰船的合并 / LOD 策略）

为什么按公告板处理（改动前必须先读懂）：
    这些素材不是实体模型，是**贴图公告板**：一个特效 = 若干四边形，每个四边形贴一张图。
    oe0350a 95 顶点 / 125 面 / 1 材质，si_eah_0130 24 顶点 / 12 面 / 4 材质 —— 全是面片。
    因此本脚本**刻意不做**舰船管线做的那些事：
      - 不合并部件（每一层都是一次独立绘制，合并会毁掉「一层一张图」的结构）
      - 不做 LOD（本来就只有十几面）
      - 不做炮塔 pivot（没有可动件）
      - 不做尺寸归一化（尺度就是原引擎尺度）
    唯一保留的是**与舰船完全一致的坐标轴处理**，以免日后把特效挂到船上时错位。

坐标推导（与 batch_obj2glb.py 一致）：
    素材 OBJ：Y 上、-Z 前  ->  Blender：Z 上、-Y 前  ->  glTF(export_yup)：Y 上、-Z 前(Godot)
    特效没有舰首概念，故不做 180 度翻转；轴系本身与舰船产物一致。

透明度怎么来（关键）：
    素材贴图全是 RGB，无 alpha 通道；原引擎用**加法混合**，黑色即透明。
    本管线同时做两件事，保证 Godot 端不管走哪条路都好看：
      1. 材质改成**自发光**：Base Color 贴图（导出后由 GLB 补丁把 baseColorFactor 压成黑色，
         等于彻底关掉漫反射）+ Emission Color ← 同一张贴图 —— 于是黑色不发光，等价加法混合。
      2. 导出前把贴图的 alpha 通道**写成亮度**（Rec.709 luma，255 = 不透明），
         并让 glTF 材质 alphaMode = BLEND —— 即使 Godot 不做加法混合，也是合理的镂空。
    两张图是同一张：RGB 原样保留，只多一条 alpha。

已实测的固定结论：
    素材贴图全部是 RGB、最大边 256（128² 占多数，也有 64x128 / 256x64 这类非方形），
    所以 --width 默认 256 时实际不会放大任何东西，只会对个例做等比缩小。

产物：
    assets/models/effects/<id>/<id>.glb     （贴图内嵌在 GLB 里，不落散图）
    tools/pipeline/model-pipeline/effects_manifest.json
"""

import argparse
import json
import math
import shutil
import struct
import sys
import tempfile
from pathlib import Path

import bpy
import numpy as np

# ---------------------------------------------------------------- 常量

SCRIPT_DIR = Path(__file__).resolve().parent
# tools/pipeline/model-pipeline -> tools/pipeline -> tools -> <repo>
REPO_ROOT = SCRIPT_DIR.parents[2]

DEFAULT_SRCS = [
    "F:/godot/model/el/scn0",
    "F:/godot/model/ek/axo/effects",
]
DEFAULT_DST = str(REPO_ROOT / "assets" / "models" / "effects")
DEFAULT_MANIFEST = str(SCRIPT_DIR / "effects_manifest.json")
DEFAULT_TEX_DIR = str(SCRIPT_DIR / ".effects_tex")

# 素材贴图的双后缀要先匹配，否则 ".agi.png" 会被 ".png" 先吃掉
TEXTURE_EXTENSIONS = (".agi.png", ".png")

# GLB 容器常量
GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942


def log(msg):
    print(f"[effects] {msg}", flush=True)


# ---------------------------------------------------------------- 场景 / 素材扫描

def clean_scene():
    """清空场景，保证每个特效都在干净环境里导入。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def parse_mtl(mtl_path: Path) -> dict:
    """解析 MTL，返回 {材质名: 贴图文件名}。素材里只有 map_Kd / map_Ka，两者指向同一张图。"""
    table = {}
    try:
        text = mtl_path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        log(f"    !! MTL 读不了 {mtl_path.name}: {e}")
        return table
    current = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        token = parts[0].lower()
        if token == "newmtl" and len(parts) > 1:
            current = parts[1].strip()
            table[current] = None
        elif token == "map_kd" and len(parts) > 1 and current:
            table[current] = parts[1].strip().strip('"')
    return table


def texture_stem(filename: str) -> str:
    """sect_01U.png -> sect_01U ; si_est_0003.agi.png -> si_est_0003"""
    for ext in TEXTURE_EXTENSIONS:
        if filename.lower().endswith(ext):
            return filename[: -len(ext)]
    return Path(filename).stem


def find_texture(tex_dir: Path, stem: str):
    """在贴图所在目录找 <stem>.png / <stem>.agi.png"""
    for ext in TEXTURE_EXTENSIONS:
        p = tex_dir / f"{stem}{ext}"
        if p.exists():
            return p
    return None


def find_obj_files(effect_dir: Path):
    """一个逻辑 ID 目录下的全部 OBJ。

    两种素材布局都要支持：
      el/scn0/<id>/<子层>/xxx.obj      （一个 ID 可能有 12 个子层目录，每个 1 个 obj）
      ek/axo/effects/<id>/xxx.obj      （obj 直接在 ID 目录下）
    """
    direct = sorted(effect_dir.glob("*.obj"))
    if direct:
        return direct
    found = []
    for sub in sorted(p for p in effect_dir.iterdir() if p.is_dir()):
        found.extend(sorted(sub.glob("*.obj")))
    return found


def collect_jobs(src_roots, only=None, limit=None):
    """扫全部素材根，目录名即逻辑 ID。"""
    jobs = {}
    for src in src_roots:
        src = Path(src)
        if not src.is_dir():
            log(f"!! 素材根不存在，跳过 {src}")
            continue
        for d in sorted(src.iterdir()):
            if not d.is_dir() or d.name.startswith("."):
                continue
            lid = d.name
            if only and lid not in only:
                continue
            objs = find_obj_files(d)
            if not objs:
                log(f"  跳过 {lid}（目录里没有 obj）")
                continue
            if lid in jobs:
                log(f"  !! 逻辑 ID 重复 {lid}：已有 {jobs[lid]['src_dir']}，又见 {d}（保留前者）")
                continue
            jobs[lid] = {"src_dir": d, "objs": objs}
    items = sorted(jobs.items())
    if limit:
        items = items[:limit]
    return dict(items)


# ---------------------------------------------------------------- 贴图：亮度 -> alpha

def alpha_stats_of(png: Path) -> dict:
    """回读已落盘的带 alpha 贴图，统计尺寸与 alpha 分布。

    回读而不是用生成时的内存数组：这样缓存命中的重跑也能报出同样的数字，
    顺便充当一次「文件确实写对了」的自检。
    """
    img = bpy.data.images.load(str(png), check_existing=False)
    try:
        img.colorspace_settings.name = "Non-Color"
        w, h = img.size
        buf = np.empty(w * h * 4, dtype=np.float32)
        img.pixels.foreach_get(buf)
    finally:
        bpy.data.images.remove(img)
    alpha = buf.reshape(h, w, 4)[:, :, 3]
    return {
        "size": [int(w), int(h)],
        "alpha_min": int(round(float(alpha.min()) * 255)),
        "alpha_max": int(round(float(alpha.max()) * 255)),
        "alpha_mean": round(float(alpha.mean()) * 255, 1),
        "alpha_opaque_ratio": round(float((alpha > 0.5).mean()), 4),
    }


def prepare_alpha_texture(src_png: Path, out_png: Path, width: int) -> dict:
    """把 RGB 贴图写成带 alpha 的贴图，alpha = Rec.709 亮度。

    读像素前把 colorspace 设成 Non-Color：这样 pixels 取到的就是文件里的原始 sRGB 数值
    （0~1，不做任何色彩空间转换），算出来的亮度才对得上肉眼看到的明暗。
    已有的输出比源文件新就直接复用，保证管线幂等、可重跑。
    """
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fresh = out_png.exists() and out_png.stat().st_mtime >= src_png.stat().st_mtime

    if not fresh:
        img = bpy.data.images.load(str(src_png), check_existing=False)
        try:
            img.colorspace_settings.name = "Non-Color"
            w, h = img.size
            if max(w, h) > width:
                scale = width / float(max(w, h))
                img.scale(max(1, int(round(w * scale))), max(1, int(round(h * scale))))
                w, h = img.size
            buf = np.empty(w * h * 4, dtype=np.float32)
            img.pixels.foreach_get(buf)
            px = buf.reshape(h, w, 4)
        finally:
            bpy.data.images.remove(img)

        luma = (0.2126 * px[:, :, 0] + 0.7152 * px[:, :, 1] + 0.0722 * px[:, :, 2])
        luma = np.clip(luma, 0.0, 1.0)

        gen = bpy.data.images.new(out_png.stem, w, h, alpha=True, float_buffer=False)
        try:
            gen.colorspace_settings.name = "Non-Color"
            gen.alpha_mode = "STRAIGHT"
            out_px = np.empty((h, w, 4), dtype=np.float32)
            out_px[:, :, 0:3] = px[:, :, 0:3]
            out_px[:, :, 3] = luma
            gen.pixels.foreach_set(out_px.reshape(-1))
            gen.update()
            gen.file_format = "PNG"
            gen.filepath_raw = str(out_png)
            gen.save()
        finally:
            bpy.data.images.remove(gen)

    stat = alpha_stats_of(out_png)
    stat["cached"] = fresh
    stat["file"] = str(out_png)
    stat["bytes"] = out_png.stat().st_size if out_png.exists() else None
    return stat


# ---------------------------------------------------------------- 材质

def mat_texture_stem(mat, mtl_table: dict):
    """从导入器生成的材质里取出贴图名（不含扩展名）；取不到就退回 MTL 表。"""
    if mat is None:
        return None
    if mat.use_nodes:
        for node in mat.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image is not None and node.image.filepath:
                return texture_stem(Path(node.image.filepath).name)
    tex_file = mtl_table.get(mat.name)
    if tex_file:
        return texture_stem(tex_file)
    return None


def build_emissive_material(stem: str, alpha_png: Path):
    """按贴图重建自发光材质（同名复用，保证同贴图只有一份材质）。"""
    name = f"MAT_{stem}"
    if name in bpy.data.materials:
        return bpy.data.materials[name]

    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (600, 0)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (300, 0)
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    img = bpy.data.images.load(str(alpha_png), check_existing=True)
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.location = (-200, 0)
    tex.image = img

    # Base Color 挂贴图是给导出器看的（它据此生成 baseColorTexture）；
    # 真正的「黑底」由导出后的 GLB 补丁把 baseColorFactor 压成 (0,0,0,1) 完成。
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
    # 自发光才是特效的本体
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 1.0
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 1.0

    # 双面（公告板从背面也要看得见）
    try:
        mat.use_backface_culling = False
    except Exception:
        pass
    # Blender 4.2 前后属性名不同，两个都试一下，纯为编辑器预览
    for attr, val in (("blend_method", "BLEND"), ("surface_render_method", "BLENDED")):
        try:
            setattr(mat, attr, val)
        except Exception:
            pass

    return mat


def build_flat_emissive_material(stem: str):
    """贴图缺失时的兜底材质：纯黑自发光（等于「看得见但什么都不画」）。"""
    name = f"MAT_{stem}"
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Base Color"].default_value = (0.0, 0.0, 0.0, 1.0)
    bsdf.inputs["Emission Color"].default_value = (0.0, 0.0, 0.0, 1.0)
    bsdf.inputs["Emission Strength"].default_value = 1.0
    return mat


def rebuild_materials(obj, tex_dir: Path, mtl_table: dict, tex_out_dir: Path,
                      alpha_stats: dict, width: int):
    """按贴图名去重重建材质槽，返回 (原槽数, 新槽数, [贴图 stem...])。

    ⚠️ 与舰船管线同一个坑：mesh.materials.clear() 会把所有 polygon.material_index 重置为 0，
    必须先缓存每个面的新索引，清空重建后再写回。
    """
    if obj.type != "MESH":
        return 0, 0, []

    old_slots = [s.material for s in obj.material_slots]
    old_count = len(old_slots)
    if old_count == 0:
        return 0, 0, []

    stems = []
    unresolved = 0
    for m in old_slots:
        stem = mat_texture_stem(m, mtl_table)
        if stem is None:
            unresolved += 1
            stem = m.name if m is not None else "unresolved"
        stems.append(stem)
    if unresolved:
        log(f"    !! {obj.name}: {unresolved}/{old_count} 个材质槽解析不到贴图名")

    uniq = []
    for s in stems:
        if s not in uniq:
            uniq.append(s)

    new_mats = []
    for stem in uniq:
        src = find_texture(tex_dir, stem)
        if src is None:
            log(f"    !! {obj.name}: 找不到贴图 {stem}.png，该层退化成无贴图自发光黑")
            new_mats.append(build_flat_emissive_material(stem))
            continue
        out_png = tex_out_dir / f"{stem}.png"
        if stem not in alpha_stats:
            alpha_stats[stem] = prepare_alpha_texture(src, out_png, width)
            a = alpha_stats[stem]
            log(f"    alpha <- {src.name} {a['size']} "
                f"alpha {a['alpha_min']}..{a['alpha_max']} 均值 {a['alpha_mean']}")
        new_mats.append(build_emissive_material(stem, out_png))

    remap = {i: uniq.index(s) for i, s in enumerate(stems)}
    cached = [remap.get(p.material_index, 0) for p in obj.data.polygons]

    obj.data.materials.clear()
    for m in new_mats:
        obj.data.materials.append(m)
    for poly, idx in zip(obj.data.polygons, cached):
        poly.material_index = idx

    return old_count, len(new_mats), uniq


# ---------------------------------------------------------------- 几何处理

def import_obj(obj_path: Path):
    """导入 OBJ（坐标轴与舰船管线保持一致），返回新建的 mesh 对象。"""
    before = set(bpy.data.objects.keys())
    bpy.ops.wm.obj_import(
        filepath=str(obj_path),
        forward_axis="NEGATIVE_Z",
        up_axis="Y",
        use_split_objects=True,
        use_split_groups=False,
    )
    new_keys = set(bpy.data.objects.keys()) - before
    return [bpy.data.objects[k] for k in new_keys if bpy.data.objects[k].type == "MESH"]


def apply_transforms(objs):
    for o in objs:
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)


def separate_by_material(obj):
    """一个 usemtl 一层：把多材质的 mesh 拆成每个材质一个对象。"""
    if len(obj.material_slots) <= 1:
        return [obj]
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    before = set(bpy.data.objects.keys())
    bpy.ops.mesh.separate(type="MATERIAL")
    after = set(bpy.data.objects.keys())
    return [obj] + [bpy.data.objects[k] for k in (after - before)
                    if bpy.data.objects[k].type == "MESH"]


def used_stems(obj):
    """该 mesh 实际用到的贴图 stem（按多边形引用的材质槽算，不含空槽）。"""
    if obj.type != "MESH":
        return []
    slots = [s.material for s in obj.material_slots]
    used = []
    for p in obj.data.polygons:
        idx = p.material_index
        if 0 <= idx < len(slots) and slots[idx] is not None:
            stem = slots[idx].name[4:] if slots[idx].name.startswith("MAT_") else slots[idx].name
            if stem not in used:
                used.append(stem)
    return used


def object_stats(obj):
    if obj.type != "MESH":
        return {"verts": 0, "faces": 0, "tris": 0}
    me = obj.data
    return {
        "verts": len(me.vertices),
        "faces": len(me.polygons),
        "tris": sum(max(0, len(p.vertices) - 2) for p in me.polygons),
    }


def world_bbox(objs):
    from mathutils import Vector
    mins = [math.inf] * 3
    maxs = [-math.inf] * 3
    for o in objs:
        if o.type != "MESH":
            continue
        mw = o.matrix_world
        for corner in o.bound_box:
            v = mw @ Vector(corner)
            for i in range(3):
                mins[i] = min(mins[i], v[i])
                maxs[i] = max(maxs[i], v[i])
    if mins[0] is math.inf:
        return None
    return {
        "min": [round(v, 3) for v in mins],
        "max": [round(v, 3) for v in maxs],
        "size": [round(maxs[i] - mins[i], 3) for i in range(3)],
    }


# ---------------------------------------------------------------- 导出 + GLB 补丁

def export_glb(objs, out_path: Path, root_name: str):
    """一个根空物体 + 每层一个 mesh 子节点。不做翻转、不做合并。"""
    out_path.parent.mkdir(parents=True, exist_ok=True)

    bpy.ops.object.empty_add(type="PLAIN_AXES", location=(0, 0, 0))
    root = bpy.context.view_layer.objects.active
    root.name = root_name

    for o in objs:
        o.parent = root
        o.matrix_parent_inverse = root.matrix_world.inverted()

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=str(out_path),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials="EXPORT",
        export_image_format="AUTO",
        export_cameras=False,
        export_lights=False,
        export_extras=True,
    )


def read_glb(path: Path):
    """拆 GLB 容器 -> (json_dict, bin_bytes)"""
    raw = path.read_bytes()
    magic, version, total = struct.unpack_from("<III", raw, 0)
    if magic != GLB_MAGIC:
        raise ValueError(f"{path.name} 不是 GLB（magic=0x{magic:08X}）")
    offset = 12
    doc = None
    binary = b""
    while offset < total:
        clen, ctype = struct.unpack_from("<II", raw, offset)
        data = raw[offset + 8: offset + 8 + clen]
        if ctype == CHUNK_JSON:
            doc = json.loads(data.decode("utf-8").rstrip("\x00 "))
        elif ctype == CHUNK_BIN:
            binary = data
        offset += 8 + clen
    if doc is None:
        raise ValueError(f"{path.name} 缺少 JSON chunk")
    return doc, binary


def write_glb(path: Path, doc: dict, binary: bytes):
    js = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    binary = binary + b"\x00" * ((4 - len(binary) % 4) % 4)
    total = 12 + 8 + len(js) + (8 + len(binary) if binary else 0)
    out = bytearray()
    out += struct.pack("<III", GLB_MAGIC, 2, total)
    out += struct.pack("<II", len(js), CHUNK_JSON) + js
    if binary:
        out += struct.pack("<II", len(binary), CHUNK_BIN) + binary
    path.write_bytes(bytes(out))


def dedupe_glb_textures(doc: dict) -> int:
    """同一个 (sampler, source) 只留一个 texture 条目。

    Blender 导出器会为 baseColor 和 emissive 各生成一个 texture 条目（同一张图），
    这里合并掉，省体积也让 Godot 侧少一份冗余贴图。
    """
    textures = doc.get("textures", [])
    if not textures:
        return 0
    keep = []
    remap = {}
    for i, tex in enumerate(textures):
        key = (tex.get("sampler"), tex.get("source"))
        if key not in remap:
            remap[key] = len(keep)
            keep.append(tex)
        remap[i] = remap[key]
    if len(keep) == len(textures):
        return 0

    def remap_ref(ref):
        if isinstance(ref, dict) and "index" in ref:
            ref["index"] = remap[ref["index"]]

    for mat in doc.get("materials", []):
        remap_ref(mat.get("emissiveTexture"))
        remap_ref(mat.get("normalTexture"))
        remap_ref(mat.get("occlusionTexture"))
        pm = mat.get("pbrMetallicRoughness", {})
        remap_ref(pm.get("baseColorTexture"))
        remap_ref(pm.get("metallicRoughnessTexture"))
    doc["textures"] = keep
    return len(textures) - len(keep)


def patch_glb_materials(path: Path) -> dict:
    """把 GLB 里的材质改成「自发光 + 亮度 alpha」形态。

    Blender 导出器没法同时表达「baseColorTexture 提供 alpha，但 RGB 要乘 0」，
    所以导出后直接补 JSON：
      - baseColorFactor = [0,0,0,1]      关掉漫反射（RGB 乘 0 变黑）
      - baseColorTexture = 同一张贴图    只为给 Godot 提供 alpha 通道
      - alphaMode = BLEND                让 Godot 的 StandardMaterial3D 走 alpha 混合
      - emissiveTexture / emissiveFactor 自发光本体
      - doubleSided = true               公告板两面都要看见
    """
    doc, binary = read_glb(path)
    textures = doc.get("textures", [])
    patched = 0
    untextured = []
    for mat in doc.get("materials", []):
        pm = mat.setdefault("pbrMetallicRoughness", {})
        emissive = mat.get("emissiveTexture")
        base = pm.get("baseColorTexture")
        tex_ref = emissive or base
        if tex_ref is None:
            # 素材里确实存在不带 map_Kd 的材质（例：si_eos_3000_GEOM_0_mat0）。
            # 原引擎加法混合下「无贴图 = 纯黑 = 什么都不加」，所以这里也让它彻底不可见，
            # 而不是让它变成一块白色实体面。
            untextured.append(str(mat.get("name", "?")))
            pm["baseColorFactor"] = [0.0, 0.0, 0.0, 0.0]
            pm["metallicFactor"] = 0.0
            pm["roughnessFactor"] = 1.0
            pm.pop("baseColorTexture", None)
            mat["emissiveFactor"] = [0.0, 0.0, 0.0]
            mat.pop("emissiveTexture", None)
            mat["alphaMode"] = "BLEND"
            mat["doubleSided"] = True
            continue
        if not textures:
            log(f"    !! {path.name} 材质 {mat.get('name')} 引用了不存在的 texture")
            continue
        pm["baseColorTexture"] = {"index": tex_ref["index"], "texCoord": tex_ref.get("texCoord", 0)}
        pm["baseColorFactor"] = [0.0, 0.0, 0.0, 1.0]
        pm["metallicFactor"] = 0.0
        pm["roughnessFactor"] = 1.0
        mat["emissiveTexture"] = {"index": tex_ref["index"], "texCoord": tex_ref.get("texCoord", 0)}
        mat["emissiveFactor"] = [1.0, 1.0, 1.0]
        mat["alphaMode"] = "BLEND"
        mat["doubleSided"] = True
        patched += 1
    if untextured:
        log(f"    无贴图材质（置为不可见）: {', '.join(untextured)}")
    merged = dedupe_glb_textures(doc)
    write_glb(path, doc, binary)

    doc2, _ = read_glb(path)
    prims = [p for m in doc2.get("meshes", []) for p in m.get("primitives", [])]
    return {
        "patched_materials": patched,
        "untextured_materials": untextured,
        "merged_texture_slots": merged,
        "glb_materials": len(doc2.get("materials", [])),
        "glb_textures": len(doc2.get("textures", [])),
        "glb_images": len(doc2.get("images", [])),
        "glb_meshes": len(doc2.get("meshes", [])),
        "glb_nodes": len(doc2.get("nodes", [])),
        "glb_primitives": len(prims),
        "_doc": doc2,
    }


def glb_triangles(doc: dict) -> int:
    acc = doc.get("accessors", [])
    total = 0
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            mode = prim.get("mode", 4)
            idx = prim.get("indices")
            if idx is not None and idx < len(acc):
                count = int(acc[idx].get("count", 0))
            else:
                pos = prim.get("attributes", {}).get("POSITION")
                count = int(acc[pos].get("count", 0)) if pos is not None else 0
            total += count // 3 if mode == 4 else 0
    return total


# ---------------------------------------------------------------- 单个特效

def process_one(lid, job, dst_root: Path, tex_dir_root: Path, width: int, do_export: bool):
    out_dir = dst_root / lid
    out_path = out_dir / f"{lid}.glb"
    tex_out_dir = tex_dir_root / lid

    clean_scene()

    alpha_stats = {}
    layers = []            # [(obj, [贴图stem...])]
    material_notes = []
    part_names = []
    verts = faces = tris = 0

    for obj_path in job["objs"]:
        src_dir = obj_path.parent
        mtl_files = sorted(src_dir.glob("*.mtl"))
        mtl_table = {}
        for mtl in mtl_files:
            mtl_table.update(parse_mtl(mtl))
        part_names.append(obj_path.parent.name)

        try:
            meshes = import_obj(obj_path)
        except Exception as e:
            log(f"    !! 导入失败 {obj_path.name}: {e}")
            continue
        if not meshes:
            log(f"    !! {obj_path.name} 没导入出网格")
            continue

        step_objs = []
        for o in meshes:
            old_n, new_n, stems = rebuild_materials(o, src_dir, mtl_table, tex_out_dir,
                                                    alpha_stats, width)
            if old_n != new_n:
                material_notes.append(f"{obj_path.parent.name}/{o.name}: {old_n} -> {new_n} 材质")
            # 按材质拆层，顺手丢掉拆出来的空壳对象
            for piece in separate_by_material(o):
                if piece.data is None or len(piece.data.polygons) == 0:
                    bpy.data.objects.remove(piece, do_unlink=True)
                    continue
                step_objs.append(piece)

        apply_transforms(step_objs)
        for o in step_objs:
            layers.append((o, used_stems(o)))

    if not layers:
        log(f"  !! {lid} 没有任何可导入网格，跳过")
        return None

    # 把 Blender 自动生成的对象名换成确定性名字：layer_00_<贴图stem>
    layers.sort(key=lambda item: (item[1][0] if item[1] else "", item[0].name))
    final_objs = []
    for i, (obj, stems) in enumerate(layers):
        stem = stems[0] if stems else "notex"
        obj.name = f"layer_{i:02d}_{stem}"
        obj.data.name = obj.name
        final_objs.append(obj)
        s = object_stats(obj)
        verts += s["verts"]
        faces += s["faces"]
        tris += s["tris"]

    bbox = world_bbox(final_objs)
    glb_info = None
    glb_tris = tris
    if do_export:
        export_glb(final_objs, out_path, lid)
        glb_info = patch_glb_materials(out_path)
        glb_tris = glb_triangles(glb_info.pop("_doc"))

    all_stems = []
    for _, stems in layers:
        for s in stems:
            if s not in all_stems:
                all_stems.append(s)

    return {
        "id": lid,
        "source": str(job["src_dir"]),
        "parts": part_names,
        "obj_files": [p.name for p in job["objs"]],
        "layer_nodes": [o.name for o in final_objs],
        "textures": all_stems,
        "verts": verts,
        "faces": faces,
        "tris": glb_tris,
        "materials": glb_info["glb_materials"] if glb_info else len(all_stems),
        "texture_count": glb_info["glb_images"] if glb_info else len(all_stems),
        "size_m": bbox["size"] if bbox else None,
        "bbox_min": bbox["min"] if bbox else None,
        "bbox_max": bbox["max"] if bbox else None,
        "alpha": alpha_stats,
        "material_notes": material_notes,
        "output": str(out_path) if do_export else None,
        "bytes": out_path.stat().st_size if (do_export and out_path.exists()) else None,
        "glb": {k: v for k, v in glb_info.items()} if glb_info else None,
    }


# ---------------------------------------------------------------- 主流程

def main():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []

    ap = argparse.ArgumentParser()
    ap.add_argument("--src", action="append",
                    help="素材根目录，可重复传入多次（不给就用默认两个）")
    ap.add_argument("--dst", default=DEFAULT_DST)
    ap.add_argument("--only", default=None)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--width", type=int, default=256)
    ap.add_argument("--tex-dir", default=None,
                    help="生成带 alpha 贴图的落地目录，默认 <本目录>/.effects_tex；"
                         "--no-export 时默认落到系统临时目录并在结束时删掉")
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    ap.add_argument("--no-export", action="store_true")
    args = ap.parse_args(argv)

    src_roots = args.src if args.src else DEFAULT_SRCS
    dst = Path(args.dst)
    manifest_path = Path(args.manifest)
    only = [s.strip() for s in args.only.split(",")] if args.only else None

    # --no-export 说的是「不写文件」，中间贴图也不该落进仓库：临时目录用完即删
    tmp_tex = None
    if args.tex_dir:
        tex_dir = Path(args.tex_dir)
    elif args.no_export:
        tmp_tex = tempfile.mkdtemp(prefix="ga-rts-effects-")
        tex_dir = Path(tmp_tex)
    else:
        tex_dir = Path(DEFAULT_TEX_DIR)

    log(f"素材源 {', '.join(str(s) for s in src_roots)}")
    log(f"输出到 {dst}")
    log(f"贴图 alpha 中转 {tex_dir}（宽度上限 {args.width}，只缩不放）")
    log(f"只做测量不写文件 {args.no_export}")

    jobs = collect_jobs(src_roots, only, args.limit)
    if not jobs:
        log("没有匹配到任何特效目录")
        return
    log(f"待处理 {len(jobs)} 个逻辑 ID")

    results = []
    for lid, job in jobs.items():
        log(f"处理 {lid} …")
        try:
            r = process_one(lid, job, dst, tex_dir, args.width, not args.no_export)
        except Exception as e:
            log(f"  !! {lid} 失败: {e}")
            import traceback
            traceback.print_exc()
            continue
        if not r:
            continue
        results.append(r)
        size = r["size_m"] or [0, 0, 0]
        log(f"  ok {lid}: {len(r['layer_nodes'])} 层 / {r['tris']} 三角面 / "
            f"{r['materials']} 材质 / {r['texture_count']} 贴图 / "
            f"尺寸 {size[0]}x{size[1]}x{size[2]}"
            + (f" / {r['bytes'] / 1024:.0f} KB" if r["bytes"] else ""))

    if args.no_export:
        if tmp_tex:
            shutil.rmtree(tmp_tex, ignore_errors=True)
        log(f"完成（未写文件）：成功 {len(results)} / 目标 {len(jobs)}")
        return

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    existing = {}
    if manifest_path.exists():
        try:
            existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        except Exception:
            existing = {}

    existing.setdefault("version", 1)
    existing["coordinate_note"] = "OBJ Y-up/-Z-fwd -> Blender Z-up -> glTF Y-up/-Z-fwd(Godot)；特效不做舰首翻转"
    existing["scale_note"] = "1:1 不缩放，原始单位≈米"
    existing["transparency_note"] = (
        "贴图 alpha = Rec.709 亮度（255 不透明）；材质 Base Color 黑 + Emission←贴图，"
        "GLB 里 alphaMode=BLEND / baseColorFactor=[0,0,0,1] / doubleSided=true"
    )
    entries = existing.setdefault("entries", {})
    for r in results:
        entries[r["id"]] = r

    total_bytes = sum(e.get("bytes") or 0 for e in entries.values())
    existing["summary"] = {
        "entries": len(entries),
        "bytes": total_bytes,
        "mib": round(total_bytes / 1024 / 1024, 2),
        "tris": sum(e.get("tris") or 0 for e in entries.values()),
        "materials": sum(e.get("materials") or 0 for e in entries.values()),
    }
    manifest_path.write_text(json.dumps(existing, ensure_ascii=False, indent=2),
                             encoding="utf-8")

    batch_bytes = sum(r["bytes"] or 0 for r in results)
    log(f"清单写入 {manifest_path}")
    log(f"完成：成功 {len(results)} / 目标 {len(jobs)}，本批 {batch_bytes / 1024 / 1024:.2f} MB；"
        f"清单累计 {len(entries)} 条 {total_bytes / 1024 / 1024:.2f} MB")


if __name__ == "__main__":
    main()
