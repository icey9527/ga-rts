class_name UnitFlight
extends RefCounted

## 分层高度（ADR-0003「分层高度：3 层 + 带内巡航 + 短暂越出」）。
##
##   L0 = -400 m   规避上层障碍、贴大型天体
##   L1 =    0 m   默认层，绝大多数交战
##   L2 = +400 m   绕开低层障碍、抢占高位
##
## 每单位有 ±150 m 容差带，巡航态被推向本层中心。允许短暂越出（追击、爬升、被击飞），
## 但必须回归 —— 回归是一条**软回拉**（速度 ∝ 偏差，上限 60 m/s），不是硬钳位：
##   · 带内：慢慢靠向中心   speed = min(60, |误差| × 1.0)
##   · 带外：全速回拉       speed = 60 m/s
## 60 m/s 特意压得比"60° 俯冲/爬升时的垂直速度"（≈155 m/s）低：这样单位仍然能靠
## 掰机头主动爬出带外（追击 / 抢高），只是松手后会被慢慢拉回本层。
##
## 本类只改 unit.accum_position.y。**不碰 x / z，不碰 forward**：水平位移只属于
## UnitMovement（位移恒为 forward × speed × dt），高度是一条独立的辅助通道
## （对应原 Lua 版 flight.lua 对 z 的弹簧趋近，3D 化后特意保留成"飞行辅助"而不是改机头）。
##
## 纯静态 + RefCounted，可脱离场景单测；不依赖任何 Node / 场景。

## 容差带半宽（米）。ADR-0003 写死 ±150
const BAND := 150.0
## 带内回拉增益（1/s）：误差 150 m 时给到 150 m/s，被 MAX_RETURN_SPEED 压到 60
const RETURN_GAIN := 1.0
## 回拉速度上限（m/s）。必须小于典型爬升速度，见文件头
const MAX_RETURN_SPEED := 60.0
## 视为"已到位"的残余误差（米），避免浮点噪声反复写 accum
const EPSILON := 1.0e-4


## 该单位在本层的巡航目标高度 = 层中心 + cruise_altitude，钳在 ±150 m 带内。
## cruise_altitude 是**相对本层中心**的偏移：层给绝对高度，单位只表达偏好。
static func cruise_target_y(unit: Unit, layer_height: float) -> float:
	if unit == null:
		return layer_height
	return clampf(layer_height + unit.cruise_altitude, band_low(layer_height), band_high(layer_height))


## 本层容差带下沿
static func band_low(layer_height: float) -> float:
	return layer_height - BAND


## 本层容差带上沿
static func band_high(layer_height: float) -> float:
	return layer_height + BAND


## 偏差（米，正 = 需要爬升）。用本 tick 已累积的位置算，所以调用顺序是
## UnitMovement.step 的最后一步（那时 accum_position 已经写好了）。
static func altitude_error(unit: Unit, layer_height: float) -> float:
	if unit == null:
		return 0.0
	return cruise_target_y(unit, layer_height) - (unit.position.y + unit.accum_position.y)


## 是否在容差带内（表现层 / AI 判断"要不要拉高度"用）
static func in_band(unit: Unit, layer_height: float) -> bool:
	return absf(altitude_error(unit, layer_height)) <= BAND


## 把 accum_position.y 朝本层中心拉。**只增不覆盖**：水平位移与高度辅助叠加在同一个
## accum_position 上，谁先谁后都不影响结果（加法交换）。
static func steer_altitude(unit: Unit, layer_height: float, dt: float) -> void:
	if unit == null or not unit.alive:
		return
	if dt <= 0.0 or not is_finite(dt):
		return
	var error := altitude_error(unit, layer_height)
	var distance := absf(error)
	if distance <= EPSILON:
		return
	var speed := minf(MAX_RETURN_SPEED, distance * RETURN_GAIN)
	if distance > BAND:
		speed = MAX_RETURN_SPEED
	# 本 tick 最多走完剩余偏差（不许冲过中心造成来回抖）
	var step_y := minf(speed * dt, distance)
	unit.accum_position.y += signf(error) * step_y
