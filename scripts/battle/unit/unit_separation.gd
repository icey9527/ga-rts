class_name UnitSeparation
extends RefCounted

## 同队单位分离（T-3.2）。
##
## 问题来源：多艘船追同一个目标时会收敛到同一点，视觉上叠成一团。
## 5v5 诊断实测两艘蓝舰坐标 `(0, 80, 1060)` 与 `(-0, 80, 1060)` —— 完全重合。
##
## 解法：**软推开**，不是硬碰撞。
##   · 只写 `accum_position`（与 UnitMovement 同一个累加器），绝不直接改 position（硬规则 3）
##   · 推力上限 30 m/s，远小于典型巡航速度 320 m/s，不会把正在追击的单位推离航线
##   · 每 tick 最多消除「剩余重叠的一半」，所以不会过冲造成来回抖
##
## 为什么只推**同队**：
##   敌军之间需要能贴脸交火，硬推开会让近战射程判定变得不可预测；
##   同队之间没有任何战术价值，推开只有好处。跨队碰撞留给以后真正的碰撞系统。

## 推开的瞬时速度上限（m/s）。必须远小于典型巡航速度
const MAX_PUSH_SPEED := 30.0
## 目标间距 = 两船半径和 × 本系数。1.05 = 刚好接触再留 5% 余量
const SEPARATION_FACTOR := 1.05
## 视为"已分开"的余量（米）
const EPSILON := 1.0e-3
## 完全重合时的退化方向。用固定的 +X，不引入随机 —— 否则同输入两次跑结果不同
const FALLBACK_AXIS := Vector3.RIGHT


## 推一步，返回本 tick 实际推开的对数（诊断用）。
##
## 只改 accum_position：调用点必须在 UnitMovement.step 之后、apply_accumulators 之前，
## 这样本 tick 的位置变化会和其他位移一起、在唯一的入口落到 position 上。
static func apply(units: Array[Unit], dt: float) -> int:
	if dt <= 0.0 or not is_finite(dt):
		return 0
	var pushed := 0
	var max_step := MAX_PUSH_SPEED * dt

	for i in units.size():
		var a := units[i]
		if a == null or not a.alive:
			continue
		for j in range(i + 1, units.size()):
			var b := units[j]
			if b == null or not b.alive:
				continue
			if a.team != b.team:
				continue

			# 用「本 tick 结束时的预计位置」判重叠，不能只看 position
			var pa := a.position + a.accum_position
			var pb := b.position + b.accum_position
			var min_dist := (a.radius + b.radius) * SEPARATION_FACTOR
			var delta := pb - pa
			var dist := delta.length()
			if dist >= min_dist - EPSILON:
				continue

			var dir: Vector3
			if dist <= EPSILON:
				# 完全重合：向量归一化会得到 NaN，必须给一个确定性方向
				dir = FALLBACK_AXIS if (a.id % 2) == 0 else -FALLBACK_AXIS
			else:
				dir = delta / dist

			# 各消除一半重叠，再做速度钳位
			var step := minf((min_dist - dist) * 0.5, max_step)
			if step <= 0.0:
				continue
			a.accum_position -= dir * step
			b.accum_position += dir * step
			pushed += 1

	return pushed
