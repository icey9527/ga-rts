class_name Formation
extends RefCounted

## 编队阵型（T-3.3，ADR-0012 机制 #2）。
##
## 职责只有一件事：**给定人数与阵型，算出每个槽位相对队形中心的本地偏移**。
## 不碰单位、不碰寻路、不碰会话 —— 纯几何，可以脱离一切上下文单测。
##
## 本地坐标约定（与引擎一致）：
##   +X = 队形向右
##   +Z = 队形**向后**（注意：舰首朝向是 -Z，所以"前排"的 z 更小）
## 槽位集合在返回前会被**去重心化**，保证整个队形的中心正好落在落点上。
##
## 为什么要阵型：不给槽位的话，一个编队移动命令会让所有单位飞向同一个点。
## 分离系统（T-3.2）能把它们推开，但那是"事后补救"—— 单位会绕着目标点挤成一团，
## 而共享终点的两艘船永远满足不了 2 m 的到站半径。槽位是**事前分配**，从根上避免。

## 阵型种类。数值要稳定（存进存档 / 地图表），加新阵型只往后追加
enum Kind {
	LINE = 0,    ## 横队：一字排开，适合正面齐射
	COLUMN = 1,  ## 纵队：首尾相接，适合狭窄通道
	WEDGE = 2,   ## 楔形：领队在前，两翼展开，默认
	BOX = 3,     ## 方阵：矩形网格，适合混编护卫
}

const KIND_COUNT := 4

const KIND_NAMES := {
	Kind.LINE: "横队",
	Kind.COLUMN: "纵队",
	Kind.WEDGE: "楔形",
	Kind.BOX: "方阵",
}

## 楔形斜向展开的纵向压缩比（不让队形拉得太长）
const WEDGE_DEPTH := 0.7


static func kind_name(kind: int) -> String:
	return str(KIND_NAMES.get(kind, "未知(%d)" % kind))


## 计算 count 个槽位的本地偏移（已去重心）。
##
## spacing = 相邻槽位的基准间距（米）。调用方应按队内最大半径来给，
## 否则大船会和小船挤在一起。
static func slot_offsets(count: int, kind: int, spacing: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if count <= 0:
		return out
	var s := maxf(spacing, 0.0)
	if count == 1:
		out.append(Vector3.ZERO)
		return out

	match kind:
		Kind.LINE:
			# 一字排开：全部同一纵深
			for i in count:
				out.append(Vector3((float(i) - float(count - 1) * 0.5) * s, 0.0, 0.0))
		Kind.COLUMN:
			# 首尾相接：领队在 z=0，后续依次靠后
			for i in count:
				out.append(Vector3(0.0, 0.0, float(i) * s))
		Kind.WEDGE:
			# 楔形：领队在最前，其余左右交替向后展开
			out.append(Vector3.ZERO)
			var k := 1
			for i in range(1, count):
				var side := 1.0 if (i % 2) == 1 else -1.0
				var rank := float((i + 1) / 2)
				out.append(Vector3(side * rank * s, 0.0, rank * s * WEDGE_DEPTH))
				k += 1
		Kind.BOX:
			# 方阵：尽量接近正方
			var cols := int(ceil(sqrt(float(count))))
			var rows := int(ceil(float(count) / float(cols)))
			for i in count:
				var row := i / cols
				var col := i % cols
				out.append(Vector3(
					(float(col) - float(cols - 1) * 0.5) * s,
					0.0,
					(float(row) - float(rows - 1) * 0.5) * s))
		_:
			# 未知阵型退化成一字排开，但必须报出来 —— 静默降级最难查
			push_error("[Formation] 未知阵型 %d，退化为横队" % kind)
			for i in count:
				out.append(Vector3((float(i) - float(count - 1) * 0.5) * s, 0.0, 0.0))

	return _recenter(out)


## 去重心：让整个队形的几何中心落在原点。
## 不做这一步的话，纵队和楔形会把整体往后拖，落点就偏了。
static func _recenter(offsets: Array[Vector3]) -> Array[Vector3]:
	if offsets.is_empty():
		return offsets
	var sum := Vector3.ZERO
	for o in offsets:
		sum += o
	var mid := sum / float(offsets.size())
	var out: Array[Vector3] = []
	for o in offsets:
		out.append(o - mid)
	return out


## 本地偏移 → 世界偏移。forward 只用它的水平分量（队形不随俯仰倾斜）。
static func to_world(local: Vector3, forward: Vector3) -> Vector3:
	var f := Vector3(forward.x, 0.0, forward.z)
	if f.length_squared() < 1.0e-6:
		f = Vector3(0.0, 0.0, -1.0)
	f = f.normalized()
	# 右手系：right = forward × up
	var right := f.cross(Vector3.UP)
	# 本地 z 是"向后"，所以沿 -f 展开
	return right * local.x - f * local.z


## 队内最大半径（决定 spacing）。没有单位返回 0。
static func max_radius(units: Array[Unit]) -> float:
	var best := 0.0
	for unit in units:
		if unit != null:
			best = maxf(best, unit.radius)
	return best


## 按队内最大半径给一个安全的间距：两船半径和再留 30% 余量。
## 用最大半径（而不是各自的）是有意的：混编时宁可整体宽松，也不要大船压小船。
static func spacing_for(units: Array[Unit]) -> float:
	return maxf(max_radius(units) * 2.0 * 1.3, 1.0)
