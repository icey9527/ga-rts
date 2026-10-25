"""S4 / T-4.1：按单一数据表生成 15 个机型的 unit.tbl 与新武器表。

设计原则（都写在这里，改数值只改本文件）：
  · 模型只用**逻辑名**（ou05 这种），真正的路径解析走 content/assets/assets.tbl 的 [ship] 段。
    换模型 = 改这张表的 model 字段，不碰任何路径。
  · radius **不手填**：由 GLB 包围盒实测后写死在表里（来源 tools/pipeline/model-pipeline/glb_bounds.py），
    保证与「1 unit = 1 m」自洽（寻路膨胀 / 分离 / 扫掠命中都吃这个数）。
  · 数值是本项目自己的平衡，不是照搬原版（原版数值是占位级别的）。

用法：
    python tools/pipeline/gen_units.py            # 生成
    python tools/pipeline/gen_units.py --dry-run  # 只打印不写文件
"""

import argparse
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UNITS_DIR = os.path.join(ROOT, "content", "units")
WEAPONS_DIR = os.path.join(ROOT, "content", "weapons")

# ---------------------------------------------------------------- 武器表
# 数值口径：DPS = damage / cooldown × count（count 在 unit.tbl 里给）
WEAPONS = {
    "machine_gun": dict(
        name="速射机炮", damage=12.0, range=450.0, cooldown=0.08,
        projectile_speed=3000.0, tracking_rate=140.0, aim_tolerance=12.0,
        note="近程防空/缠斗。单炮塔 DPS 150，靠高转速跟住掠过的小目标。",
    ),
    "shotgun": dict(
        name="散弹炮", damage=22.0, range=500.0, cooldown=0.9,
        projectile_speed=1400.0, tracking_rate=60.0, aim_tolerance=15.0,
        note="中近程扇形覆盖。单发低伤高频，靠多炮塔数量压面。",
    ),
    "sniper_beam": dict(
        name="贯穿光束", damage=900.0, range=3000.0, cooldown=6.0,
        projectile_speed=4000.0, tracking_rate=8.0, aim_tolerance=1.5,
        note="全场最远。转速与容差都极小 —— 打不中移动目标，专打直线冲刺或静止目标。",
    ),
    "artillery_cannon": dict(
        name="重力炮", damage=260.0, range=2200.0, cooldown=3.0,
        projectile_speed=1200.0, tracking_rate=12.0, aim_tolerance=6.0,
        note="三炮口重击。弹速慢，需要预判；配合多门齐射压制大型目标。",
    ),
    "missile_pod": dict(
        name="导弹巢", damage=180.0, range=1600.0, cooldown=2.4,
        projectile_speed=900.0, tracking_rate=45.0, aim_tolerance=12.0,
        note="中远程压制。弹速慢但单发高伤，适合打大目标与掩护推进。",
    ),
    "repair_beam": dict(
        name="维修光束", damage=8.0, range=400.0, cooldown=1.2,
        projectile_speed=2000.0, tracking_rate=90.0, aim_tolerance=20.0,
        note="维修机的自卫武器。伤害刻意忽略不计 —— 真正的用途（维修）尚未实现，"
             "留一条能开火的路径避免它被当成无效单位。",
    ),
}

# ---------------------------------------------------------------- 机型表
# radius 来自 GLB 包围盒实测（最长边 ÷ 2），不要手改
# 字段：model, radius, hp, speed, yaw(度/秒), pitch, alt(巡航高度偏移), weapon, count, spread
ROLES = [
    ("light",            "ou09",  4.11,   1600, 380, 45, 30,  80, "pulse_cannon",      2, (1.5, 0.0, 0.0)),
    ("scout",            "ou172", 14.85,  1700, 400, 40, 26,  80, "machine_gun",       2, (2.0, 0.0, 0.0)),
    ("interceptor",      "ou03",  19.64,  1900, 420, 50, 33,  80, "machine_gun",       2, (3.0, 0.0, 0.0)),
    ("repair",           "ou07",  5.59,   1800, 300, 35, 23,  80, "repair_beam",       1, (0.0, 0.0, 0.0)),
    ("fighter",          "ou05",  31.81,  4200, 320, 30, 20,  80, "pulse_cannon",      2, (3.0, 0.0, 0.0)),
    ("gunship",          "ou107", 30.32,  3600, 260, 25, 17,  40, "shotgun",           2, (4.0, 0.0, 0.0)),
    ("sniper",           "ou06",  26.46,  3000, 240, 20, 13,  40, "sniper_beam",       1, (0.0, 0.0, 0.0)),
    ("artillery",        "ou04",  19.47,  3400, 220, 18, 12,   0, "artillery_cannon",  3, (5.0, 0.0, 0.0)),
    ("bomber",           "ou236", 46.37,  6000, 300, 15, 10, 100, "missile_pod",       2, (6.0, 0.0, 0.0)),
    ("collector",        "ou137", 100.44, 8000,  60, 10,  7,   0, "machine_gun",       1, (0.0, 0.0, 0.0)),
    ("missile_frigate",  "ou231", 92.23,  9000, 200, 12,  8,   0, "missile_pod",       4, (8.0, 0.0, 0.0)),
    ("tiger",            "ou232", 158.85, 12000, 280, 14,  9,  40, "artillery_cannon",  2, (10.0, 0.0, 0.0)),
    ("heavy",            "ou134", 175.87, 12800, 180, 12,  6,   0, "heavy_beam",        4, (0.0, 4.5, 0.0)),
    ("carrier",          "ou235", 300.65, 20000, 130,  6,  4,   0, "heavy_beam",        2, (0.0, 20.0, 0.0)),
    ("mothership",       "ou241", 561.76, 26000,  90,  4,  3,   0, "heavy_beam",        6, (0.0, 30.0, 0.0)),
]

CN_NAMES = {
    "light": ("轻型快攻机", "双舷齐发爆破，轻快灵活，靠数量与速度淹没对手。"),
    "scout": ("电子侦察机", "战场的眼睛。速度快、装甲薄，负责前出探路与骚扰。"),
    "interceptor": ("拦截机", "舰队最快。专抓对方的轰炸机与侦察机，缠斗性能最好。"),
    "repair": ("维修机", "火力几乎为零，但能显著延长整支舰队的续航。"),
    "fighter": ("多用途战机", "中距离主力。速度、火力、生存都均衡，编队的骨干。"),
    "gunship": ("散弹炮艇", "中近距离扇形覆盖，一轮打多个目标，克制密集编队。"),
    "sniper": ("远程狙击机", "全场最远的贯穿光束。只能打直线或静止目标，需要队友牵制。"),
    "artillery": ("力场炮机", "三炮口重击，弹速慢需预判，对大型舰体收益最高。"),
    "bomber": ("高空轰炸机", "巡航高度最高，从上方压制密集舰群。"),
    "collector": ("资源采集站", "几乎不动的后方设施。火力仅够自卫。"),
    "missile_frigate": ("导弹轰击舰", "四座导弹巢持续压制，单发高伤，专治大型目标。"),
    "tiger": ("虎式重击机", "重装突击。舰艏重撞配合重炮，用来撕开对方阵型。"),
    "heavy": ("重型护卫舰", "舰队抗线核心。慢但可靠，四门重炮压制中距离。"),
    "carrier": ("轻型航母", "厚血支援舰。双门重炮 + 高结构强度，为编队撑住正面。"),
    "mothership": ("指挥母舰", "战场核心。六门重炮，全场最高的血量与体积。"),
}


def weapon_tbl(weapon_id, spec):
    return f"""; ============================================================
; {weapon_id} —— {spec['name']}
;
; {spec['note']}
;
; 射程 {spec['range']:.0f} m / 冷却 {spec['cooldown']} s / 弹速 {spec['projectile_speed']:.0f} m/s
; 单炮塔 DPS = {spec['damage']:.0f} / {spec['cooldown']} = {spec['damage'] / spec['cooldown']:.0f}
; ============================================================
[weapon]
name             = "{spec['name']}"
damage           = {spec['damage']}
range            = {spec['range']}
cooldown         = {spec['cooldown']}
projectile_speed = {spec['projectile_speed']}
tracking_rate    = {spec['tracking_rate']}
aim_tolerance    = {spec['aim_tolerance']}
"""


def unit_tbl(role, model, radius, hp, speed, yaw, pitch, alt, weapon, count, spread):
    cn, desc = CN_NAMES[role]
    accel = max(1.0, round(speed * 0.5, 1))
    decel = max(1.0, round(speed * 0.6, 1))
    armor = min(80, max(5, int(hp / 200)))
    shield = int(hp * 0.35)
    radar = int(2000 + radius * 3)
    cost = int(hp / 30)
    sx, sy, sz = spread
    return f"""; ============================================================
; {cn}（{role}）
;
; {desc}
;
; radius 来自 GLB 包围盒实测（{model} 最长边 {radius * 2:.2f} m ÷ 2），
; **不要手改** —— 寻路膨胀 / 单位分离 / 扫掠命中都吃这个值。
; model 是逻辑名，解析走 content/assets/assets.tbl 的 [ship] 段；换模型只改那一行。
; ============================================================
[stats]
name      = "{cn}"
speed     = {speed}
max_hp    = {hp}
armor     = {armor}
shield    = {shield}
radar     = {radar}
cost      = {cost}
acceleration    = {accel}
deceleration    = {decel}
turn_rate_yaw   = {yaw}
turn_rate_pitch = {pitch}
radius          = {radius}
cruise_altitude = {alt}

[assets]
model     = {model}

[weapon]
main        = {weapon}
count:int   = {count}
spread:vec3 = {sx:g},{sy:g},{sz:g}
"""


def write(path, text, dry_run):
    if dry_run:
        print(f"  [dry] {os.path.relpath(path, ROOT)}")
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print(f"  wrote {os.path.relpath(path, ROOT)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    print(f"武器表（{len(WEAPONS)} 个新增）")
    for weapon_id, spec in WEAPONS.items():
        write(os.path.join(WEAPONS_DIR, weapon_id, "weapon.tbl"), weapon_tbl(weapon_id, spec), args.dry_run)

    print(f"机型表（{len(ROLES)} 个）")
    for row in ROLES:
        role = row[0]
        write(os.path.join(UNITS_DIR, role, "unit.tbl"), unit_tbl(*row), args.dry_run)

    print("完成。")


if __name__ == "__main__":
    main()
