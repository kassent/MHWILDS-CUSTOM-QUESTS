-- 任务 10098 (零式欧米茄复刻) 运行时定制脚本。
-- 生命周期由插件宿主管理: cQuestSceneLoading 时装载本脚本, cQuestResult 时销毁 state 并自动摘钩;
--   公共逻辑(敌人注入/对话目录/台词 NPC)在 scripts/quest_lib.lua(require 装载, per-state 隔离),
--   本文件只保留任务专属数据与装配。
--
-- 功能块:
--   1. 对话目录     手动加载原 Omega 任务的对话目录(自定义任务不在其目标列表, 不加台词沉默)
--   2. 预放置敌人   QUEST_ENEMY_SPAWNS 表驱动注入(影蜘蛛联动召唤 + 掩体植物)
--   3. 台词 NPC     补 spawn 欧米茄台词的两个说话 NPC
--   4. 大招配置     中心与蓄力点独立; 爆炸长轴平行于蓄力点到中心, 爆炸整体缩放, 伤害不变
-- (高难增强版 —— 动作速度/火海寿命/暴走锁定/双蜘蛛 —— 见 10099.lua)

local lib = require("scripts.quest_lib")
local print = lib.print


-- ==================== 1. 对话目录 ====================

local OMEGA_MISSION_FIXED = 26820 -- Ms730020 零式欧米茄 (Dia_stCh7301_Ms730020_*)

-- ==================== 2. 预放置敌人 ====================
-- entry 字段文档见 scripts/quest_lib.lua(与 pog ContextLayoutEnemy 节点同名字段一一对照)。
-- 触发器: EnemyManager.createMainTargetContext —— updateChangeLayout 的 STORY 分支,
--   每个客户端(任何座位)的任务布局流程必经(四组联机实测; layouter 触发依赖场景有非空敌人图,
--   干净客户端不成立)。post 阶段等原生主怪创建落地后注入。

local ROLE_ID = lib.ROLE_ID
local ENEMY_LAYOUT_TYPE = lib.ENEMY_LAYOUT_TYPE

local QUEST_ENEMY_SPAWNS = {
    { -- 影蜘蛛(欧米茄 SpAtk 召唤用, 参数照抄 st402_SubBoss_Ms730025 节点 / 自制 pog 实测值)
        _EmID = -1363370496, -- EM0070_00_0
        _RoleID = ROLE_ID.ROLE_COLLAB_01,
        _OptionTag = 1,
        _StoryTargetID = 10, -- 对齐 _SubBossInfoArray._EmTargetID
        _Position = { 12.509, -0.254, 89.623 },                     -- 竞技场中心(pog 实测位置)
        _DifficultyRankId = "f326f227-c0ff-47bb-92e7-aa187d61ad3c", -- Ms630007 蜘蛛节点难度
        _AdvancedSettings = { _IsDefaultDeepSleep = true },
    },
    -- 掩体植物×4, 参数照抄 st402_Em5010/5011_00_0_AnimalContextLayout 节点:
    --   零难度 GUID / 固定体型 100 / _OptionTag=1 入睡变体(出生 t+10s 自行隐形埋地, STANDBY 通道);
    --   Omega 大招 checkSpAtkSummonStarted → wakeUpEm5010Em5011 按区域位自动唤醒, 结束 exitEm5010Em5011 移除
    { -- 魔界花幼苗 EM5011_00_0 (南侧, 实测点)
        _EmID = 31768,
        _OptionTag = 1,
        _LayoutType = ENEMY_LAYOUT_TYPE.DEFAULT,
        _Position = { 14.050, 0.089, 67.122 },
        _DifficultyRankId = "00000000-0000-0000-0000-000000000000",
    },
    { -- 魔界花幼苗 EM5011_00_0 (北侧, 实测点)
        _EmID = 31768,
        _OptionTag = 1,
        _LayoutType = ENEMY_LAYOUT_TYPE.DEFAULT,
        _Position = { 8.506, -0.299, 111.814 },
        _DifficultyRankId = "00000000-0000-0000-0000-000000000000",
    },
    { -- 仙人刺 EM5010_00_0 (东侧, 实测点)
        _EmID = 9549,
        _OptionTag = 1,
        _LayoutType = ENEMY_LAYOUT_TYPE.DEFAULT,
        _Position = { 30.620, -0.284, 90.972 },
        _DifficultyRankId = "00000000-0000-0000-0000-000000000000",
    },
    { -- 仙人刺 EM5010_00_0 (西侧, 与东侧点关于蜘蛛对称补的, 朝向镜像)
        _EmID = 9549,
        _OptionTag = 1,
        _LayoutType = ENEMY_LAYOUT_TYPE.DEFAULT,
        _Position = { -5.602, -0.284, 90.972 },
        _DifficultyRankId = "00000000-0000-0000-0000-000000000000",
    },
}

sdk.hook(sdk.find_type_definition("app.EnemyManager"):get_method("createMainTargetContext(app.FieldDef.STAGE, System.Boolean)"),
    function(args)
        local storage = thread.get_hook_storage()
        storage.em = sdk.to_managed_object(args[2])
        storage.stage = sdk.to_int64(args[3]) & 0xFFFFFFFF
    end,
    function(retval)
        local storage = thread.get_hook_storage()
        if storage.em ~= nil then
            lib.spawn_preplaced_enemies(storage.em, storage.stage, QUEST_ENEMY_SPAWNS)
        end
    end)

-- ==================== 3. 台词 NPC ====================
-- 位置用本任务竞技场中心附近(st403), 原 st402 坐标不适用。
-- 触发器: 阿尔玛(fixed 86)是任务必刷 NPC, 她的 createContextHolder_Npc 时刻场景必然已加载,
--   比 cQuestPlaying 更早更稳。我们自己的 spawn 会重入本 hook, 但 NpcID 不匹配触发条件, 不会递归。

local OMEGA_SPEAKER_NPCS = {
    { fixed = 25679, pos = { -2.297, 0.426, 73.488 } }, -- NPC510_50_030 游星欧米茄 (begin NPC)
    { fixed = 16659, pos = { -4.0, 0.426, 71.0 } },     -- NPC510_50_026 欧米茄 (第二 actor)
}

local NPC102_00_001 = 8 -- 0x8 alma
local speaker_spawned = false
sdk.hook(sdk.find_type_definition("app.ContextManager"):get_method("createContextHolder_Npc(app.cContextCreateArg_Npc)"), function(args)
    if speaker_spawned then
        return
    end
    local arg = sdk.to_managed_object(args[3])
    if arg:call("get_NpcID()") == NPC102_00_001 then
        speaker_spawned = true
        lib.spawn_speaker_npcs(OMEGA_SPEAKER_NPCS)
    end
end)

-- ==================== 4. 大招配置 ====================
-- 起飞/无罩激光与爆炸共用中心; CHARGE_POS用于原生绕飞目标，不直接设置怪物Transform。
-- 原生 loadArgmentData 在非 ST402 会将 StartPos 清为世界原点, 因此必须 post 写回。
-- Nullable<via.vec3> 修改后写回整个字段; 此方式已经临时 ShootingInfo 对象往返验证。
local ATTACK_CENTER = Vector3f.new(-6.099601, 5, 98.362564)
-- local CHARGE_POS = Vector3f.new(-42.243317, 5, 99.290459)
local CHARGE_POS = Vector3f.new(-32.265949, 5, 98.130585)
local BURST_SCALE = 1.5 -- 整体缩放: 原版半径42/端点Z=±30 -> 半径63/端点Z=±45
local BURST_YAW = math.atan(ATTACK_CENTER.x - CHARGE_POS.x, ATTACK_CENTER.z - CHARGE_POS.z)
local BURST_ROTATION = Quaternion.new(math.cos(BURST_YAW / 2), 0, math.sin(BURST_YAW / 2), 0)

-- 4.1 爆炸出生参数: 仅Creator 47 / Shell 26; 不改激光、伤害或EffectScale。
sdk.hook(sdk.find_type_definition("app.cAppShellShooter"):get_method("loadArgmentData(ace.user_data.ShellCreatorInfoDataBase.ShellCreatorInfoArgumentBase, app.cShellShootingInfo, ace.user_data.ShellCreatorInfoDataBase.ShellCreatorInfoBase, app.cAppShellShooter.overWriteOffset)"),
    function(args)
        local storage = thread.get_hook_storage()
        storage.info = nil
        local arg = sdk.to_managed_object(args[3])
        if arg == nil or arg:get_type_definition():get_full_name() ~= "app.Em0166_00SpAtkBurstShellCreatorInfoArgument" then
            return
        end
        local creator = sdk.to_managed_object(args[5])
        if creator:get_field("_UniqueID") == 47 and creator:get_field("_ShellListNo") == 26 then
            storage.info = sdk.to_managed_object(args[4])
        end
    end,
    function(retval)
        local info = thread.get_hook_storage().info
        if info ~= nil then
            local pos = info:get_field("<StartPos>k__BackingField")
            pos:set_field("_HasValue", true)
            pos:set_field("_Value", ATTACK_CENTER)
            info:set_field("<StartPos>k__BackingField", pos)

            local rot = info:get_field("<StartRot>k__BackingField")
            rot:set_field("_HasValue", true)
            rot:set_field("_Value", BURST_ROTATION)
            info:set_field("<StartRot>k__BackingField", rot)

            local scale = info:get_field("<Scale>k__BackingField")
            scale:set_field("_HasValue", true)
            scale:set_field("_Value", Vector3f.new(BURST_SCALE, BURST_SCALE, BURST_SCALE))
            info:set_field("<Scale>k__BackingField", scale)

            print("burst center=(%.6f, %.6f, %.6f), yaw=%.6f, scale=%.3f",
                ATTACK_CENTER.x, ATTACK_CENTER.y, ATTACK_CENTER.z, math.deg(BURST_YAW), BURST_SCALE)
        end
        return retval
    end)

local VEC3_TYPE = sdk.find_type_definition("via.vec3")

-- 4.2 跨场景getter修正: 非ST402原生返回固定中心或相对蓄力坐标。
-- post直接用配置常量覆写世界坐标，不读取ParamUnique或缓存位置。
-- 起飞/召唤区域与无罩激光读取中心；有防护罩时仍走原生防护罩分支。
sdk.hook(sdk.find_type_definition("app.cEm0166_00Extend"):get_method("getSpAtkCenterPos()"),
    nil,
    function(retval)
        sdk.set_native_field(retval, VEC3_TYPE, "x", ATTACK_CENTER.x)
        sdk.set_native_field(retval, VEC3_TYPE, "y", ATTACK_CENTER.y)
        sdk.set_native_field(retval, VEC3_TYPE, "z", ATTACK_CENTER.z)
        print("getSpAtkCenterPos -> (%.6f, %.6f, %.6f)", ATTACK_CENTER.x, ATTACK_CENTER.y, ATTACK_CENTER.z)
        return retval
    end)

sdk.hook(sdk.find_type_definition("app.cEm0166_00Extend"):get_method("getSpAtkChargePos()"),
    nil,
    function(retval)
        sdk.set_native_field(retval, VEC3_TYPE, "x", CHARGE_POS.x)
        sdk.set_native_field(retval, VEC3_TYPE, "y", CHARGE_POS.y)
        sdk.set_native_field(retval, VEC3_TYPE, "z", CHARGE_POS.z)
        print("getSpAtkChargePos -> (%.6f, %.6f, %.6f)", CHARGE_POS.x, CHARGE_POS.y, CHARGE_POS.z)
        return retval
    end)


-- 4.3 小欧米茄运行时落点：不修改共享参数或召唤数组。
-- 由任务脚本生命周期限定作用域；仅修正大招DIRECT召唤，保留随机偏移与高度。
-- 隐藏vec3返回缓冲：args[3]=this，args[4]=原点，args[5]=候选点，已CLI核对。
sdk.hook(sdk.find_type_definition("app.cEm0166_00Extend"):get_method("checkSaftySummonPos(via.vec3, via.vec3)"),
    function(args)
        local ext = sdk.to_managed_object(args[3])
        if not ext:get_field("_IsRequestCallServant") or ext:get_field("_RequestSummonType") ~= 2 then
            return
        end
        -- 原候选XZ = 原组XZ - 当前参数中心XZ + 随机偏移。
        -- 加新中心 + 当前参数中心 - 原版中心，恢复阵型相对原版中心的偏移。
        local center = ext:call("get_ParamUnique()"):get_field("_SpAtkCenterPos")
        local x = sdk.get_native_field(args[5], VEC3_TYPE, "x")
        local y = sdk.get_native_field(args[5], VEC3_TYPE, "y")
        local z = sdk.get_native_field(args[5], VEC3_TYPE, "z")
        local shifted_x = x + ATTACK_CENTER.x + center.x + 302.645752
        local shifted_z = z + ATTACK_CENTER.z + center.z - 824.168091
        sdk.set_native_field(args[5], VEC3_TYPE, "x", shifted_x)
        sdk.set_native_field(args[5], VEC3_TYPE, "z", shifted_z)
    end)

-- ==================== 5. 绕飞动画混合基准（试验） ====================
-- 原生 blend=wrap(yaw-106.533996)/360；仅替换本次 Round 调用中的混合输入。
-- 这是动画混合基准，不保证最终朝向等于该值，也可能影响绕飞落点。
-- 使用配置蓄力点指向中心的水平角，与爆炸长轴一致；弧度转角度并归一化。
local ROUND_BASE_YAW = math.deg(BURST_YAW) % 360
-- post覆盖试验：原生已启动动画，是否赶得上轨迹初始化需实测。
local set_blend_rate = sdk.find_type_definition("app.CharacterUtil"):get_method(
    "setVariableBlendRate(via.motion.Motion, System.Single, System.Nullable`1<System.UInt32>)")
local BLEND_ID_TYPE = sdk.find_type_definition("System.Nullable`1<System.UInt32>")

sdk.hook(sdk.find_type_definition("app.Em0166_00Action.cSpAtkRound"):get_method("doEnter()"),
    function(args)
        local storage = thread.get_hook_storage()
        local action = sdk.to_managed_object(args[2])
        local character = action:call("get_Chara()")
        local em_mot = character:call("get_EmMot()")
        storage.motion = em_mot and em_mot:call("get_MotionComponent()")
        if storage.motion == nil then return end
        local rotation = character:call("get_GameObject()"):call("get_Transform()"):call("get_Rotation()")
        local forward = rotation * Vector3f.new(0, 0, 1)
        storage.yaw = math.deg(math.atan(forward.x, forward.z)) % 360
    end,
    function(retval)
        -- TU5原函数正常返回NORMAL=0前已调用setVariableBlendRate和setMotionGroup。
        local result = sdk.to_int64(retval) & 0xFFFFFFFF
        if result ~= 0 then
            print("Round post skipped: enter result=%d", result)
            return retval
        end
        local storage = thread.get_hook_storage()
        if storage.motion == nil then return retval end
        local blend = ((storage.yaw - ROUND_BASE_YAW) % 360) / 360
        local variable_id = ValueType.new(BLEND_ID_TYPE)
        variable_id:set_field("_HasValue", true)
        variable_id:set_field("_Value", 0x067C962F)
        set_blend_rate:call(nil, storage.motion, blend, variable_id)
        print("Round post blend=%.6f; entry yaw=%.6f; base yaw=%.6f",
            blend, storage.yaw, ROUND_BASE_YAW)
        return retval
    end)
    
-- ==================== 生命周期 ====================
quest.on_load(function()
    -- 声明本任务场景需要的 EnemyDef.ID_Fixed: 宿主 hook setStageResidentDataDicts 时
    --   合并进当前场景 _EmIDList(不限场景), 场景即可刷新它们(环境生物不在 Boss+Zako 全量范围)
    quest.require_enemies{
        31768, -- EM5011_00_0 魔界花幼苗
        9549,  -- EM5010_00_0 仙人刺
    }
    lib.load_mission_dialogues(OMEGA_MISSION_FIXED)
    print("quest script loaded")
end)

-- 记录任务流程变化。
quest.on_flow_changed(function(flow)
    print("flow: %s", flow)
end)

quest.on_unload(function()
    lib.unload_mission_dialogues(OMEGA_MISSION_FIXED)
    print("unloading quest script, hooks will be removed")
end)
