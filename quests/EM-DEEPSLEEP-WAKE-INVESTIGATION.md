# 敌人深眠/唤醒双通道调查（2026-08-17）

起源问题：官方零式欧米茄任务里仙人刺/魔界花掩护植物**何时创建、为何隐形、大招时如何集体出现**。
本文记录完整反编译链 + live CLI 实验 + 最终可复用配方。逆向底座（create/同步模型/pog）见
`MP-SPIDER-INVESTIGATION.md` 与记忆节点。

---

## 一、结论速览

| | STANDBY 通道 | FSM 通道 |
|---|---|---|
| 入睡方式 | create arg `OptionTag≠0`，出生后 t+8~10s 自行入睡 | create 时 `CreateOptionBit bit4`（FROM_STORY，蜘蛛同款） |
| 挂的 CAUSE 位 | STANDBY=4 | FSM=2 |
| 唤醒调用 | `requestWakeup(STANDBY=4, ...)` | `requestWakeup(FSM=2, ...)` |
| 官方消费者 | `wakeUpEm5010Em5011`（植物，带区域位过滤） | `requestCollaboEmAppear`（EM0070 蜘蛛 + ROLE_COLLAB_01） |
| 睡眠表现 | 隐形埋地（IsHide） | 隐形埋地（同构） |
| 跨物种 | ✓ 花/刺都验证 | ✓ 花/刺都验证 |

核心规则：**入睡入口决定挂哪个 cause 位，唤醒必须用同一个 cause**——`requestWakeup`
开头检查该位是否在 `_DeepSleepCause` 位集里，没置位直接静默跳过。两条通道互不通用，
但任何物种都能任选一条。

状态判据（read: `AIStateManager`）：
- `_CurrentAIInterruptID` == 0 → 深眠中（DEEP_SLEEP）；-1 → 醒
- `_CurrentAIStateID`：1 = 普通待机（**不是睡**）；12 = 活跃（被唤醒后）

## 二、反编译链（TU5 Ghidra，函数+地址）

### 2.1 官方大招召唤序列

`app.cEm0166_00Extend::checkSpAtkSummonStarted` @0x147475fc0
（**host 门禁**：NetInfo 无 host 或我就是 host 才执行）：

```c
// 找到 RoleID==ROLE_COLLAB_01 且 AIInterruptID==DEEP_SLEEP 的 EM0070 蜘蛛时:
requestCollaboEmAppear();                              // ① 唤醒蜘蛛(FSM)
AnimalUtil::wakeUpEm5010Em5011(FieldAreaInfo);         // ② 唤醒全部区域匹配植物(STANDBY)
```

`requestCollaboEmAppear` @0x145605770：`findEnemyList_EmID(EM0070)` →
RoleID==ROLE_COLLAB_01 → `requestWakeup(FSM)`。
`requestCollaboEmDeepSleep` @0x1456056b0：反向打回催眠（Extend 模块置标志，AI 状态机消费）。

`app.AnimalUtil::wakeUpEm5010Em5011(cFieldAreaInfo)` @0x147719dd0：
先循环 EM5010（仙人刺）再循环 EM5011（魔界花），逐只检查
`_Chara._FieldAreaInfo._MergedAreaBit_EnemyCombatArea & 参数位集 != 0`（**区域位过滤**：
只醒与参考区域相交的植物）→ `requestWakeup(STANDBY)`。
⚠ 直接整调该函数对不在竞技场战斗区的植物无效（实测）；绕过法见 4.3。

### 2.2 requestWakeup 语义

`app.cEmModuleEvent.cRequestDeepSleepArg::requestWakeup` @0x147a06e70，
签名 `(CAUSE, cEnemyContextHolder, bool sendPacket)`：

1. 检查 CAUSE 位在 `_DeepSleepCause` 位集 → 无则静默返回（**配对模型根源**）
2. 清除该 cause 位
3. `_OptionByCause[cause]` 全关：`IsHide/IsEnableNagamono/IsEnableGravity/IsEnableMotion/IsEnableCollider/IsDisableSensed = false`（**IsHide 即隐形**）
4. `_IsRequestDeepSleep = true`
5. host 且 sendPacket=true → **发网络包同步唤醒**（官方联机通道，客人跟着醒）

CAUSE 枚举 `app.cEmModuleEvent.cRequestDeepSleepArg.CAUSE`：

```
CUT_SCENE_ACTOR = 0   CUT_SCENE_NO_ACTOR = 1   FSM = 2（蜘蛛/bit4）
CULLING = 3           STANDBY = 4（植物/opt变体）   UNIQUE = 5
```

### 2.3 官方布局配置（pog json 证据）

两个物种的布局文件（JSON dump 本地路径，`D:\dev\MHWs-in-json\natives\MHWs-in-json-main\MHWs-in-json-main\natives\` 下）：

- 仙人刺 EM5010：`STM\GameDesign\Stage\st402\Layout\Loaded\Animal\PointGraph\ContextLayout\st402_Em5010_00_0_AnimalContextLayout.pog.12.json`
- 魔界花 EM5011：`STM\GameDesign\Stage\st402\Layout\Loaded\Animal\PointGraph\ContextLayout\st402_Em5011_00_0_AnimalContextLayout.pog.12.json`

- 节点 `_IsDefaultDeepSleep: **false**`、`_IsDefaultDie: false` —— **隐形深眠不是布局 flag 给的**
- EmID 在 graph 级 `cSharedData._EmId`（`_IsSetEmIdInPointData=false`），节点 `_EmID=INVALID`
- 节点 `_OptionTag` json 里两个物种都写 1；活体 create-dump 显示刺 opt=2 / 花 opt=1。
  **实测刺 opt=1 和 opt=2 都入睡** → 非 0 即睡；json 与日志的差异不影响行为
- **OptionTag 变体注册表**（`STM/GameDesign/Enemy/CommonData/Data/EnemyIndividualCommonData.user.3.json`，
  210 物种）：每 EmID 一条 `cCommonParam`，`_OptionTagInfos` 每项只有
  `{"_OptionTagBit", "_IsNetSync"}` 两字段——**是变体注册表不是行为配置表**（行为差异在物种
  AI 按 tag 实现；`_IsNetSync` 是 create() 网络同步门控的数据源）。植物注册位：仙人刺
  (fixed=9549) bit1+bit2、魔界花(fixed=31768) bit1+bit2、影蜘蛛(-1363370496) bit1+bit2、
  欧米茄(21849) bit1
- 其他：`_LayoutTag=6`、`_GroupID=0`、`_SetAreaNo=255`、难度/路线 GUID 全零
- 数量：仙人刺 graph=1 nodes5-9（5 只）、魔界花 graph=2 nodes0-2（3 只）；stage enum 10 ↔ st402

### 2.4 创建路径

任务装载时布局链 `create(STATIC, makeStaticContextId(stage, graph, node), ONLY_LOCAL)`，
`bits=[]` 空（**不走 create 深眠位**）。自定义任务在同场景自动得到这批植物——Omega AI +
场景图驱动，不依赖 quest 配置。

## 三、live 实验记录（按时间序）

| # | 实验 | 结果 |
|---|---|---|
| 1 | 官方植物状态 dump | 3 花+5 刺全部 `state=1 interrupt=0`（睡） |
| 2 | 花 opt=0 出生 | `interrupt=-1`，**可见**站着待机 |
| 3 | 花 opt=1 出生 | t+8s `interrupt=0`，**隐形**埋地 |
| 4 | 整调 `wakeUpEm5010Em5011(自身FAI)` | 未唤醒——区域位过滤拦下（站位不在竞技场战斗区） |
| 5 | 直连 `requestWakeup(STANDBY)` 单只 | 唤醒成功，**带破土出场特效**（官方大招同款） |
| 6 | 4 只 opt=1 花分别用 FSM/CULLING/STANDBY/UNIQUE 唤 | 只有 **STANDBY** 醒，其余静默无效果 |
| 7 | 花 opt=0 + create bit4 | t+8s 入睡，`requestWakeup(FSM)` 唤醒成功 |
| 8 | 刺 opt=2 / opt=1 | 都入睡，STANDBY 都能唤醒 |
| 9 | 刺 opt=0 + bit4 | 入睡，FSM 唤醒成功 |

被手动激活的植物过一段时间会**自然消失**（官方掩护植物同款生命周期）。

## 四、可复用配方（Lua）

### 4.1 官方植物式：出生隐形埋地

```lua
arg:set_field("<OptionTag>k__BackingField", 1)  -- 任意非 0（花=1/刺=1 或 2 均实测入睡）
-- 其余 arg 同普通 STATIC 布局怪（LayoutType=0, bits 不动）
-- t+8~10s 自动进 DEEP_SLEEP。位置在竞技场战斗区时 Omega 大招会自动扫醒（wakeUpEm5010Em5011）
```

### 4.2 蜘蛛式：create 即睡（FSM 通道，任何物种可用）

```lua
local bits = arg:get_field("<CreateOptionBit>k__BackingField")
bits:call("on(System.Int32)", 4)  -- DEFAULT_DEEP_SLEEP_FROM_STORY
```

### 4.3 手动唤醒（绕过区域位过滤器）

```lua
local ctx = info:call("get_Context()")          -- cEnemyContextHolder
local rdsa = ctx:get_field("_Em"):get_field("Event"):get_field("RequestDeepSleepArg")
rdsa:call("requestWakeup(app.cEmModuleEvent.cRequestDeepSleepArg.CAUSE, app.cEnemyContextHolder, System.Boolean)",
    4, ctx, true)   -- 按入睡通道选: STANDBY=4(opt变体) / FSM=2(bit4)；true=host发包MP同步
```

### 4.4 睡眠预判

```lua
local ai = ctx:get_field("_Em"):get_field("AIStateManager")
local asleep = ai:get_field("_CurrentAIInterruptID") == 0
```

## 五、live CLI 工具链（ref-skill-cli）

游戏运行时直连（IPC 插件已装于游戏目录），不必重启/改 mod：

```bash
~/.claude/skills/reframework-skill/ref-skill-cli.exe eval-lua --script '<lua code>'
```

- 返回 `ok/value` 或 `error`；eval 失败只报错不崩游戏（安全）
- **跨 eval 持久状态**：Lua 全局变量（如 `__PLANT_PROBE = { info = ... }`）存在同一
  REFramework Lua 环境里，先存后读
- 安全边界：只读状态/写字段/调官方方法（本文全部 requestWakeup/addSystemLog 类）安全；
  新建/绑定 native 对象、RequestQueue.trigger 之类有崩溃前科，勿在 live 裸调
- 游戏内通知：`sdk.get_managed_singleton("app.ChatManager"):call("addSystemLog(System.String)", "...")`

### 5.1 完整探针脚本模板（本文实验用的就是它）

```lua
local em = sdk.get_managed_singleton("app.EnemyManager")
local pm = sdk.get_managed_singleton("app.PlayerManager")
local stage = sdk.get_managed_singleton("app.MasterFieldManager"):get_CurrentStage()
local tf = pm:getMasterPlayer():get_Object():get_Transform()
local pos = tf:get_Position()

local arg = sdk.find_type_definition("app.cContextCreateArg_Enemy"):create_instance()
local transform = sdk.find_type_definition("app.cContextTransform"):create_instance()
transform:set_field("<Position>k__BackingField", Vector3f.new(pos.x, pos.y, pos.z + 4.0))
transform:set_field("<Rotation>k__BackingField", tf:get_Rotation())
arg:set_field("<Transform>k__BackingField", transform)
arg:set_field("<EmID>k__BackingField", 75)          -- 74=仙人刺 75=魔界花
arg:set_field("<RoleID>k__BackingField", 0)
arg:set_field("<LegendaryID>k__BackingField", 0)
arg:set_field("<LayoutType>k__BackingField", 0)
arg:set_field("<StageNo>k__BackingField", stage)
arg:set_field("<OptionTag>k__BackingField", 1)      -- 0=醒 / 非0=入睡变体
arg:set_field("<StoryTargetID>k__BackingField", 0)
arg:set_field("<LayoutKeepID>k__BackingField", -1)
arg:set_field("<GroupID>k__BackingField", 0)
arg:set_field("<EventTargetID>k__BackingField", -1)
arg:set_field("<IsMainTarget>k__BackingField", false)
arg:set_field("<AreaNo>k__BackingField",
    em:call("getAreaNoNearPoint(via.vec3, app.FieldDef.STAGE)", pos, stage))
-- 可选: bits:call("on(System.Int32)", 4) 走 FSM 通道
local contextId = sdk.find_type_definition("app.EnemyUtil")
    :get_method("makeStaticContextId(app.FieldDef.STAGE, System.Int32, System.Int32, System.Boolean, System.Boolean)")
    :call(nil, stage, 200, 952, false, true)        -- graph=200/node=9xx 避开真实布局
local info = em:call(
    "create(app.EnemyDef.CONTEXT_SUB_CATEGORY, System.Int32, app.cContextCreateArg_Enemy, app.EnemyDef.SYNC_TYPE, via.GameObject)",
    0, contextId, arg, 2, nil)                      -- STATIC / ONLY_LOCAL
```

### 5.2 批量状态 dump

```lua
local list = em:findEnemyList_EmID(75)   -- 管理数组支持 #list 与 list[i]
for i = 0, #list - 1 do
  local ai = list[i]:get_Context():get_field("_Em"):get_field("AIStateManager")
  -- ai:get_field("_CurrentAIStateID") / _CurrentAIInterruptID
end
```

## 六、遗留问题

1. `_MergedAreaBit_EnemyCombatArea` 的 lua 字段名未找到（读 nil），区域位过滤只能整调
   官方函数时被动生效；想主动利用过滤需 C++/后续逆向
2. pog json（刺=1）与活体日志（刺=2）的 opt 差异源头未定（dump 过时 vs animal 路径改写），
   已实证不影响入睡行为
3. `EnemyManager._NoParentContextHandleList` 的**消费链（谁遍历释放）未查完**——
   10096/10098/10099.lua 已按用户拍板登记该账本；若后续出重复销毁/残留优先怀疑
4. `wakeUpEm5010Em5011` 区域过滤对"玩家附近自定义植物"不生效——自定义怪用直连
   requestWakeup 替代
