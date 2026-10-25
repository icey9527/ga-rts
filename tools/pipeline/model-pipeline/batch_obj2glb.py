"""
batch_obj2glb.py — Project Sylpheed 模型批量转换管线（OBJ -> GLB）

用法（Blender headless）：
    blender -b -P batch_obj2glb.py -- [选项]

选项：
    --src <dir>       素材根目录，默认 F:/godot/model/el/scn1
    --dst <dir>       输出根目录，默认 F:/godot/ga-rts/assets/models
    --only <ids>      只处理指定逻辑 ID，逗号分隔，如 ou05,ou134
    --limit <n>       最多处理 n 个逻辑 ID（冒烟测试用）
    --flip-forward    把模型绕 Blender Z 轴转 180 度（当舰首在 -Z 时使用）
    --no-export       只做测量与报告，不写文件
    --manifest <path> 清单输出路径

设计依据：
    ADR-0005 模型管线、ADR-0009 单一 SB 自动 LOD、ADR-0011 工具分离

坐标推导（重要，改动前先看这里）：
    素材 OBJ：Y 上、-Z 前（Blender OBJ 导入器默认声明）
    -> Blender：Z 上、-Y 前
    -> glTF（export_yup=True）：Y 上、-Z 前 = Godot 前向
    所以素材里 +Z 若为舰首，导出后舰首在 Godot 的 -Z，正是惯例。
    若实测舰首在 -Z，用 --flip-forward 修正。

尺度：1:1，不做缩放。
    实测素材尺度合理（无人机 8m / 护卫舰 63m / 巡洋舰 350m / 母舰 764m），
    因此原始单位≈米。若个别需要缩放，写在 UnitDef 的 scale 字段，不改模型。
"""

import bpy
import os
import sys
import json
import argparse
import math
from pathlib import Path

# ---------------------------------------------------------------- 常量

# 需要独立旋转的部件（炮塔类）：保留为独立节点并把原点移到自身包围盒中心
TURRET_KEYWORDS = ("cannon", "aag", "laser", "missile", "pod", "drill", "turret", "gun")

# 纹理后缀
SUFFIX_DIFFUSE = ""
SUFFIX_EMISSIVE = "_lum"
SUFFIX_NORMAL = "_bmp"
SUFFIX_METALLIC = "_ref"

DEFAULT_SRC = "F:/godot/model/el/scn1"
DEFAULT_DST = "F:/godot/ga-rts/assets/models"

KIND_BY_PREFIX = {
    "ou": "ships",
    "ob": "objects",
}


# ---------------------------------------------------------------- 工具函数

def log(msg):
    print(f"[pipeline] {msg}", flush=True)


def clean_scene():
    """清空场景，保证每个模型都在干净环境里导入。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def parse_id(dirname):
    """从目录名提取 逻辑ID 与 精度档。  ou134a -> (ou134, a) ; ob1501a -> (ob1501, a)"""
    name = dirname
    if not name or name[-1] not in "abc":
        return None, None
    tier = name[-1]
    base = name[:-1]
    if not (base.startswith("ou") or base.startswith("ob")):
        return None, None
    if not base[2:].isdigit():
        return None, None
    return base, tier


def is_turret_part(part_name):
    low = part_name.lower()
    return any(k in low for k in TURRET_KEYWORDS)


def find_texture(base_dir: Path, stem: str, suffix: str):
    """在 base_dir 里找 <stem><suffix>.png，兼容 .agi.png 双后缀。"""
    for name in (f"{stem}{suffix}.png", f"{stem}{suffix}.agi.png"):
        p = base_dir / name
        if p.exists():
            return p
    return None


def image_stem_from_material(mat):
    """从导入器生成的材质里取出漫反射贴图名（不含扩展名）并剥离 _lum/_bmp/_ref 后缀。"""
    if mat is None or not mat.use_nodes:
        return None
    for node in mat.node_tree.nodes:
        if node.type != "TEX_IMAGE" or node.image is None:
            continue
        fname = Path(node.image.filepath).name
        # 去掉扩展名（含 .agi.png 双后缀）
        for ext in (".agi.png", ".png", ".tga", ".jpg", ".bmp"):
            if fname.lower().endswith(ext):
                fname = fname[: -len(ext)]
                break
        for sfx in (SUFFIX_EMISSIVE, SUFFIX_NORMAL, SUFFIX_METALLIC):
            if fname.endswith(sfx):
                fname = fname[: -len(sfx)]
                break
        # 我们只认带 _0 / _1 ... 的漫反射名
        return fname
    return None


def build_material(stem: str, tex_dir: Path):
    """按贴图名重建一个确定性的 PBR 材质。已存在则复用。"""
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

    # 基础色
    diffuse = find_texture(tex_dir, stem, SUFFIX_DIFFUSE)
    if diffuse:
        img = bpy.data.images.load(str(diffuse), check_existing=True)
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.location = (-200, 200)
        tex.image = img
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])

    # 自发光
    emissive = find_texture(tex_dir, stem, SUFFIX_EMISSIVE)
    if emissive:
        img = bpy.data.images.load(str(emissive), check_existing=True)
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.location = (-200, -60)
        tex.image = img
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = 1.0

    # 法线（源素材里叫 _bmp，是 bump 图；先按法线图接，若效果不对再改为高度->法线）
    normal = find_texture(tex_dir, stem, SUFFIX_NORMAL)
    if normal:
        img = bpy.data.images.load(str(normal), check_existing=True)
        img.colorspace_settings.name = "Non-Color"
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.location = (-420, -320)
        tex.image = img
        nmap = nt.nodes.new("ShaderNodeNormalMap")
        nmap.location = (-200, -320)
        nt.links.new(tex.outputs["Color"], nmap.inputs["Color"])
        nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])

    # 金属度 / 粗糙度：有反射图就抬高金属度，否则当作非金属
    has_ref = find_texture(tex_dir, stem, SUFFIX_METALLIC) is not None
    bsdf.inputs["Metallic"].default_value = 0.45 if has_ref else 0.05
    bsdf.inputs["Roughness"].default_value = 0.55

    return mat


def rebuild_materials(obj, tex_dir: Path):
    """把导入器生成的（大量重复）材质槽，改成按贴图去重的少数几个。
    返回 (原槽数, 新槽数)。"""
    if obj.type != "MESH":
        return 0, 0

    old_slots = [s.material for s in obj.material_slots]
    old_count = len(old_slots)
    if old_count == 0:
        return 0, 0

    # 原槽 -> 贴图名
    stem_of_old = []
    unresolved = 0
    for m in old_slots:
        stem = image_stem_from_material(m)
        if stem is None and m is not None:
            stem = m.name
        if stem is None:
            unresolved += 1
        stem_of_old.append(stem)
    if unresolved:
        log(f"    !! {obj.name}: {unresolved}/{old_count} 个材质槽无法解析贴图名，已归入 0 号材质")

    # 去重，保持首次出现顺序
    uniq = []
    for s in stem_of_old:
        if s is not None and s not in uniq:
            uniq.append(s)

    if not uniq:
        return old_count, old_count

    new_mats = [build_material(s, tex_dir) for s in uniq]
    remap = {}
    for i, s in enumerate(stem_of_old):
        remap[i] = uniq.index(s) if s in uniq else 0

    # 关键：必须先把每个多边形的新材质索引算好并缓存下来。
    # Blender 的 mesh.materials.clear() 会把所有 polygon.material_index 重置为 0，
    # 因此"先设索引再清槽表"会导致所有面挤到 0 号材质（静默丢贴图）。
    cached = [remap.get(p.material_index, 0) for p in obj.data.polygons]

    obj.data.materials.clear()
    for m in new_mats:
        obj.data.materials.append(m)

    # 槽表重建完成后再写回索引
    for poly, idx in zip(obj.data.polygons, cached):
        poly.material_index = idx

    return old_count, len(new_mats)


def import_obj(obj_path: Path):
    """导入一个 OBJ，返回导入创建的 mesh 对象列表。"""
    before = set(bpy.data.objects.keys())
    bpy.ops.wm.obj_import(
        filepath=str(obj_path),
        forward_axis="NEGATIVE_Z",
        up_axis="Y",
        use_split_objects=True,
        use_split_groups=False,
    )
    after = set(bpy.data.objects.keys())
    return [bpy.data.objects[k] for k in (after - before)]


def apply_transforms(objs):
    for o in objs:
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)


def set_origin_to_bounds(obj):
    """把原点移到自身包围盒中心（炮塔类部件需要，否则绕整船原点甩）。"""
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")


def join_objects(objs, new_name):
    """把多个对象合并成一个。"""
    if not objs:
        return None
    if len(objs) == 1:
        objs[0].name = new_name
        objs[0].data.name = new_name
        return objs[0]
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    merged = bpy.context.view_layer.objects.active
    merged.name = new_name
    merged.data.name = new_name
    return merged


def object_stats(obj):
    if obj.type != "MESH":
        return {"verts": 0, "tris": 0, "materials": 0}
    me = obj.data
    tris = sum(max(0, len(p.vertices) - 2) for p in me.polygons)
    return {
        "verts": len(me.vertices),
        "tris": tris,
        "materials": len(obj.material_slots),
    }


def world_bbox(objs):
    """所有对象合并后的世界包围盒 (min, max, size)。"""
    mins = [math.inf] * 3
    maxs = [-math.inf] * 3
    for o in objs:
        if o.type != "MESH":
            continue
        mw = o.matrix_world
        for corner in o.bound_box:
            v = mw @ __import__("mathutils").Vector(corner)
            for i in range(3):
                mins[i] = min(mins[i], v[i])
                maxs[i] = max(maxs[i], v[i])
    if mins[0] is math.inf:
        return None
    size = [round(maxs[i] - mins[i], 3) for i in range(3)]
    return {
        "min": [round(v, 3) for v in mins],
        "max": [round(v, 3) for v in maxs],
        "size": size,
    }


def export_glb(objs, out_path: Path, flip_forward: bool):
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # 一个根空物体，保持层级干净
    bpy.ops.object.empty_add(type="PLAIN_AXES", location=(0, 0, 0))
    root = bpy.context.view_layer.objects.active
    root.name = out_path.stem

    for o in objs:
        o.parent = root
        o.matrix_parent_inverse = root.matrix_world.inverted()

    if flip_forward:
        root.rotation_euler[2] = math.pi

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


# ---------------------------------------------------------------- 主流程

def collect_jobs(src: Path, only=None, limit=None):
    """扫描 a 档目录，按逻辑 ID 归组 SB 模型。"""
    jobs = {}
    for d in sorted(src.iterdir()):
        if not d.is_dir():
            continue
        lid, tier = parse_id(d.name)
        if lid is None or tier != "a":
            continue
        if only and lid not in only:
            continue

        parts = []
        for part_dir in sorted(d.iterdir()):
            if not part_dir.is_dir():
                continue
            # 只收属于本逻辑 ID 的部件。
            # 例：ob1505a/ 里同时放了 SB_ob1505A 和 SB_ou241E，后者属于 ou241，不能拼进 ob1505。
            if lid.lower() not in part_dir.name.lower():
                log(f"   跳过异物 {d.name}/{part_dir.name}（不属于 {lid}）")
                continue
            objs = sorted(part_dir.glob("SB_*.obj"))
            if not objs:
                continue
            parts.append({"part": part_dir.name, "obj": objs[0]})

        if parts:
            jobs[lid] = {"src_dir": d, "parts": parts}

    items = sorted(jobs.items())
    if limit:
        items = items[:limit]
    return dict(items)


def process_one(lid, job, dst_root: Path, flip_forward: bool, do_export: bool):
    kind = KIND_BY_PREFIX.get(lid[:2], "misc")
    out_dir = dst_root / kind / lid
    out_path = out_dir / f"{lid}.glb"

    clean_scene()

    imported = []          # [(part_name, obj)]
    material_notes = []
    for p in job["parts"]:
        before = set(bpy.data.objects.keys())
        try:
            bpy.ops.wm.obj_import(
                filepath=str(p["obj"]),
                forward_axis="NEGATIVE_Z",
                up_axis="Y",
                use_split_objects=True,
                use_split_groups=False,
            )
        except Exception as e:
            log(f"  !! 导入失败 {p['obj'].name}: {e}")
            continue
        new_keys = set(bpy.data.objects.keys()) - before
        new_objs = [bpy.data.objects[k] for k in new_keys if bpy.data.objects[k].type == "MESH"]
        if not new_objs:
            continue

        tex_dir = p["obj"].parent
        for o in new_objs:
            o.name = f"{p['part']}" if len(new_objs) == 1 else f"{p['part']}_{o.name}"
            old_n, new_n = rebuild_materials(o, tex_dir)
            if old_n != new_n:
                material_notes.append(f"{p['part']}: {old_n} -> {new_n} 材质")
        apply_transforms(new_objs)
        imported.append((p["part"], new_objs))

    if not imported:
        log(f"  !! {lid} 没有任何可导入网格，跳过")
        return None

    # 炮塔类保留独立，其余合并成一个 body
    body_objs, turret_objs = [], []
    for part_name, objs in imported:
        if is_turret_part(part_name):
            for o in objs:
                set_origin_to_bounds(o)
                o.name = f"turret_{part_name}"
                turret_objs.append(o)
        else:
            body_objs.extend(objs)

    body = join_objects(body_objs, "body")
    final_objs = ([body] if body else []) + turret_objs

    stats = {"verts": 0, "tris": 0, "materials": 0}
    for o in final_objs:
        s = object_stats(o)
        stats["verts"] += s["verts"]
        stats["tris"] += s["tris"]
        stats["materials"] += s["materials"]

    bbox = world_bbox(final_objs)

    if do_export:
        export_glb(final_objs, out_path, flip_forward)

    return {
        "id": lid,
        "kind": kind,
        "parts": [p["part"] for p in job["parts"]],
        "source": str(job["src_dir"]),
        "output": str(out_path) if do_export else None,
        "size_m": bbox["size"] if bbox else None,
        "bbox_min": bbox["min"] if bbox else None,
        "bbox_max": bbox["max"] if bbox else None,
        "verts": stats["verts"],
        "tris": stats["tris"],
        "materials": stats["materials"],
        "turret_nodes": [o.name for o in turret_objs],
        "material_notes": material_notes,
        "bytes": out_path.stat().st_size if (do_export and out_path.exists()) else None,
    }


def main():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []

    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--dst", default=DEFAULT_DST)
    ap.add_argument("--only", default=None)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--flip-forward", action="store_true")
    ap.add_argument("--no-export", action="store_true")
    ap.add_argument("--manifest", default=None)
    args = ap.parse_args(argv)

    src = Path(args.src)
    dst = Path(args.dst)
    only = [s.strip() for s in args.only.split(",")] if args.only else None

    log(f"素材源 {src}")
    log(f"输出到 {dst}")
    log(f"翻转前向 {args.flip_forward} | 只导出报告 {args.no_export}")

    jobs = collect_jobs(src, only, args.limit)
    if not jobs:
        log("没有匹配到任何 a 档模型")
        return

    log(f"待处理 {len(jobs)} 个逻辑 ID: {', '.join(jobs.keys())}")

    results = []
    seen_files = {}
    for lid, job in jobs.items():
        key = tuple(sorted(str(p["obj"]) for p in job["parts"]))
        if key in seen_files:
            log(f"  跳过 {lid}（与 {seen_files[key]} 源文件相同）")
            continue
        seen_files[key] = lid

        log(f"处理 {lid} …")
        try:
            r = process_one(lid, job, dst, args.flip_forward, not args.no_export)
        except Exception as e:
            log(f"  !! {lid} 失败: {e}")
            import traceback
            traceback.print_exc()
            continue
        if r:
            results.append(r)
            sz = r["size_m"]
            log(f"  ok {lid}: {r['tris']} 三角面, {r['materials']} 材质, "
                f"尺寸 {sz[0]}x{sz[1]}x{sz[2]}, 节点 {len(r['turret_nodes'])} 炮塔")

    manifest_path = Path(args.manifest) if args.manifest else (
        dst.parent.parent / "tools" / "pipeline" / "model-pipeline" / "manifest.json"
    )
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    existing = {}
    if manifest_path.exists():
        try:
            existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        except Exception:
            existing = {}

    existing.setdefault("version", 1)
    existing["coordinate_note"] = "OBJ Y-up/-Z-fwd -> Blender Z-up -> glTF Y-up/-Z-fwd(Godot)"
    existing["scale_note"] = "1:1 不缩放，原始单位≈米"
    entries = existing.setdefault("entries", {})
    for r in results:
        entries[r["id"]] = r
    manifest_path.write_text(
        json.dumps(existing, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    log(f"清单写入 {manifest_path}")
    log(f"完成：成功 {len(results)} / 目标 {len(jobs)}")


if __name__ == "__main__":
    main()
