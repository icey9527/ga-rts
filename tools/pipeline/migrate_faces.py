"""S5 / 立绘迁移：把原版角色头像搬进 assets，并建立机型→角色的映射。

## 为什么要这张卡
头顶徽章、单位列表、详情面板都需要"小头像"。原版的头像是**角色（飞行员）立绘**，
不是舰船图 —— 那批资源（content/teams/<team>/chara/<id>/face/fac*.png）在 S0.5
完全没迁，所以我们只能画机型缩写当占位。

## 做法
1. 对每个需要的角色 id，读 `face.tbl` 的 `#000`（普通表情），把那个 png 复制到
   `assets/ui/faces/<chara>.png`
2. 只迁 #000：其余表情（攻击/受击/战败…）等有对应表现系统（受击闪红、阵亡播报）再补，
   现在迁 9 张/人只是白占磁盘
3. 机型 → 角色的映射写在 gen_units.py 的 PORTRAITS 表里（单一数据源），
   由它写进各机型的 unit.tbl `[portrait] chara = <id>`

## 用法
    python tools/pipeline/migrate_faces.py            # 迁移
    python tools/pipeline/migrate_faces.py --dry-run  # 只看会复制什么
"""

import argparse
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_ROOT = r"E:\ai_rts-main\rts_game\content\teams\default\chara"
DST_DIR = os.path.join(ROOT, "assets", "ui", "faces")

# 机型 → 角色编号。**任选但固定**：原版靠"谁驾驶这艘船"决定头像，
# 我们没有飞行员概念，所以按定位配一个顺眼的角色，改这里即可换人。
PORTRAITS = {
    "light": "023",
    "scout": "024",
    "interceptor": "027",
    "repair": "028",
    "fighter": "029",
    "gunship": "030",
    "sniper": "032",
    "artillery": "033",
    "bomber": "034",
    "collector": "035",
    "missile_frigate": "036",
    "tiger": "037",
    "heavy": "038",
    "carrier": "039",
    "mothership": "040",
    "ou05": "042",
    "ou134": "043",
}


def read_face_zero(chara_id):
    """读 face.tbl 里的 #000 文件名。找不到返回 None。"""
    tbl = os.path.join(SRC_ROOT, chara_id, "face.tbl")
    if not os.path.isfile(tbl):
        return None
    with open(tbl, "r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("#000="):
                return line.split("=", 1)[1].strip()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(SRC_ROOT):
        print(f"[faces] 源目录不存在：{SRC_ROOT}", file=sys.stderr)
        return 1

    missing = []
    copied = 0
    for role, chara in sorted(PORTRAITS.items()):
        face_name = read_face_zero(chara)
        if face_name is None:
            missing.append(f"{role}: 角色 {chara} 没有 face.tbl 的 #000 条目")
            continue
        src = os.path.join(SRC_ROOT, chara, "face", face_name)
        if not os.path.isfile(src):
            missing.append(f"{role}: 文件不存在 {src}")
            continue
        dst = os.path.join(DST_DIR, f"{chara}.png")
        if args.dry_run:
            print(f"  [dry] {role:18} chara {chara}  {face_name} -> assets/ui/faces/{chara}.png")
            continue
        os.makedirs(DST_DIR, exist_ok=True)
        shutil.copyfile(src, dst)
        copied += 1
        print(f"  {role:18} chara {chara}  {face_name} -> assets/ui/faces/{chara}.png")

    if missing:
        print("\n[faces] 有 %d 条没能迁移：" % len(missing), file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    if not args.dry_run:
        print(f"\n[faces] 完成：复制 {copied} 张到 assets/ui/faces/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
