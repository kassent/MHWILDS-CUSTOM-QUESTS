-- 任务 10099 (终末四重奏·高难) 运行时定制脚本。
-- 生命周期由插件宿主管理: cQuestSceneLoading 时装载本脚本, cQuestResult 时销毁 state 并自动摘钩;
--   公共逻辑(敌人注入/对话目录/台词 NPC)在 scripts/quest_lib.lua(require 装载, per-state 隔离),
--   本文件只保留任务专属数据与装配。
--
-- 功能块:
--   1. 对话目录     手动加载原 Omega 任务的对话目录(自定义任务不在其目标列表, 不加台词沉默)
--   2. 动作速度     白炽龙/黑蚀龙/欧米茄动作提速(package 加载时改 Legendary 参数)
--   3. 火海寿命     芥末炸弹火海出生即无限寿命
--   4. 暴走锁定     欧米茄暴走不可被脚伤击破解除
--   5. 预放置敌人   QUEST_ENEMY_SPAWNS 表驱动注入(双影蜘蛛联动召唤 + 掩体植物)
--   6. 台词 NPC     补 spawn 欧米茄台词的两个说话 NPC
--   7. 龙乳结晶     普通地面也可生成GM651结晶，保留原生结晶效果
--   8. 大招配置     欧米茄中心/蓄力目标、爆炸朝向与缩放、小欧米茄运行时落点
--   9. 绕飞混合     doEnter post覆盖blend，基准取蓄力点指向中心的水平角
--  10. 生命周期     常驻怪物声明、对话装卸、增强参数还原及任务流程日志

local lib = require("scripts.quest_lib")

local print = lib.print

-- ==================== 1. 对话目录 ====================

local OMEGA_MISSION_FIXED = 26820 -- Ms730020 零式欧米茄 (Dia_stCh7301_Ms730020_*)

-- ==================== 2. 动作速度 ====================
-- hook EnemyManager 的 package 加载/卸载。加载完成后沿着
--   _PackageHolders[EmID]._PackageData._ParamPack._Legendary 逐级访问, 对表内 EmID 写
--   MotionSpeedRate / MotionSpeedRate_Hard, 卸载时还原。
-- 备份表持有 obj 引用: 既防对象被提前释放, 还原时也不用重新走 EnemyManager 逐级查。

local MOTION_SPEED_PATCHES = {
    [32] = 1.2, -- 白炽龙
    [10] = 1.2, -- 黑蚀龙
    [34] = 1.3, -- 游星欧米茄
}

local motion_speed_patched = {} -- EmID -> { obj = legendary 对象, rate/rateHard = 原值 }

local function restore_motion_speed_patch(id)
    local b = motion_speed_patched[id]
    if b == nil then
        return
    end
    local cur, curHard = b.obj.MotionSpeedRate, b.obj.MotionSpeedRate_Hard
    b.obj.MotionSpeedRate = b.rate
    b.obj.MotionSpeedRate_Hard = b.rateHard
    motion_speed_patched[id] = nil
    print("restored motion speed for EmID=%d(%s): MotionSpeedRate %.2f -> %.2f, MotionSpeedRate_Hard %.2f -> %.2f", id, lib.get_enemy_display_name(id), cur, b.rate, curHard, b.rateHard)
end

-- args[1]=vmctx args[2]=this args[3]=EmID(32位枚举: to_int64 后 & 0xFFFFFFFF 截出来)
sdk.hook(sdk.find_type_definition("app.EnemyManager"):get_method("onLoadPackage(app.EnemyDef.ID)"), function(args)
    local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
    print("onLoadPackage EmID=%d(%s)", id, lib.get_enemy_display_name(id))

    local em = sdk.to_managed_object(args[2])
    local holder = em._PackageHolders[id]
    if holder == nil then
        return
    end
    ---@field getPackage fun(self, arg0: app.EnemyDef.ID): app.user_data.EnemyPackage public 0x1455f90c0 / id: 611130
    local legendary = holder._PackageData._ParamPack._Legendary
    if legendary == nil then
        return
    end
    local targetSpeed = MOTION_SPEED_PATCHES[id]
    if targetSpeed ~= nil then
        local rate, rateHard = legendary.MotionSpeedRate, legendary.MotionSpeedRate_Hard
        motion_speed_patched[id] = { obj = legendary, rate = rate, rateHard = rateHard }
        legendary.MotionSpeedRate = targetSpeed
        legendary.MotionSpeedRate_Hard = targetSpeed
        print("patched motion speed for EmID=%d(%s): MotionSpeedRate %.2f -> %.2f, MotionSpeedRate_Hard %.2f -> %.2f", id, lib.get_enemy_display_name(id), rate, legendary.MotionSpeedRate, rateHard, legendary.MotionSpeedRate_Hard)
    end
end)

sdk.hook(sdk.find_type_definition("app.EnemyManager"):get_method("onUnloadRequestPackage(app.EnemyDef.ID)"), function(args)
    local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
    print("onUnloadRequestPackage EmID=%d(%s)", id, lib.get_enemy_display_name(id))
    restore_motion_speed_patch(id)
end)

-- ==================== 3. 火海寿命 ====================
-- 芥末炸弹火海(MasteredBombSlipArea)出生即无限寿命:
--   ShellBase.update 的寿命守卫是 `0 < _LifeSec && LifeTimer 超时`, 写 0 即引擎"无寿命"语义。
--   _CommonParam 是该 Omega 本次加载的 ShellList 里共享的源头数据: 第一颗火海写入后,
--   同场后续火海(读同一份数据)出生即无限; 每只新 Omega 加载新副本, hook 幂等覆盖。
--   注意: 只去掉 120s 自然寿命, SlipArea::update 的"新一轮施法清场"仍在,
--   火海最长活到 Omega 下一次放芥末炸弹(或死亡/任务结束)。

local slip_lifetime_patched = {} -- [{ obj = CommonParam, orig = 原 LifeSec }]

sdk.hook(sdk.find_type_definition("app.mcShellMiniParamEm0166_00MasteredBombSlipArea"):get_method("onSetup()"), function(args)
    local this = sdk.to_managed_object(args[2])
    if this == nil then
        return
    end
    local shell = this:call("get_Shell()")
    local setting = shell ~= nil and shell:call("get_Setting()") or nil
    if setting == nil then
        return
    end
    local mainParam = setting:get_field("_MainParam")
    local cp = mainParam ~= nil and mainParam:get_field("_CommonParam") or nil
    if cp == nil then
        return
    end
    local life = cp:get_field("_LifeSec")
    if life > 0 then
        cp:set_field("_LifeSec", 0.0)
        slip_lifetime_patched[#slip_lifetime_patched + 1] = { obj = cp, orig = life }
        print("slip area lifetime %.1f -> infinite", life)
    end
end)

local function restore_slip_lifetime()
    for _, b in ipairs(slip_lifetime_patched) do
        b.obj:set_field("_LifeSec", b.orig)
    end
    if #slip_lifetime_patched > 0 then
        print("restored slip area lifetime for %d CommonParam(s)", #slip_lifetime_patched)
    end
    slip_lifetime_patched = {}
end

-- ==================== 4. 暴走锁定 ====================
-- 全能之主(Rampage)不可被脚伤击破解除:
--   subRampageDownVital @0x14746bbb0 每次击破脚伤扣暴走血条的 _ScarRampageDownRate(_HL)%(原生 35),
--   扣到见底才 endRampageMode + 长倒地。写 0 → 每次扣 0, 血条永不见底,
--   只剩 _RampageTime 计时(零式 600s)和第 2 次暴走的血量线(零式 10%)能退出。
--   ParamUnique 是 per-Omega 实例数据(extend.get_ParamUnique()), 每只新 Omega 各一份;
--   hook 每次进暴走前幂等写入(rate==0 跳过)。

local rampage_rate_patched = {} -- [{ obj = ParamUnique, orig = 原rate, origHl = 原rate_HL }]

sdk.hook(sdk.find_type_definition("app.cEm0166_00Extend"):get_method("startRampageMode()"), function(args)
    local ext = sdk.to_managed_object(args[2])
    local pu = ext ~= nil and ext:call("get_ParamUnique()") or nil
    if pu == nil then
        return
    end
    local rate = pu:get_field("_ScarRampageDownRate")
    if rate == 0 then
        return
    end
    local rateHl = pu:get_field("_ScarRampageDownRate_HL")
    pu:set_field("_ScarRampageDownRate", 0)
    pu:set_field("_ScarRampageDownRate_HL", 0)
    rampage_rate_patched[#rampage_rate_patched + 1] = { obj = pu, orig = rate, origHl = rateHl }
    print("rampage scar down rate %d/%d -> 0/0 (leg scar break no longer exits rampage)", rate, rateHl)
end)

local function restore_rampage_rate()
    for _, b in ipairs(rampage_rate_patched) do
        b.obj:set_field("_ScarRampageDownRate", b.orig)
        b.obj:set_field("_ScarRampageDownRate_HL", b.origHl)
    end
    if #rampage_rate_patched > 0 then
        print("restored rampage scar down rate for %d ParamUnique(s)", #rampage_rate_patched)
    end
    rampage_rate_patched = {}
end

-- ==================== 5. 预放置敌人 ====================
-- entry 字段文档见 scripts/quest_lib.lua(与 pog ContextLayoutEnemy 节点同名字段一一对照)。
-- 触发器: EnemyManager.createMainTargetContext —— updateChangeLayout 的 STORY 分支,
--   每个客户端(任何座位)的任务布局流程必经(四组联机实测; layouter 触发依赖场景有非空敌人图,
--   干净客户端不成立)。post 阶段等原生主怪创建落地后注入。

local ROLE_ID = lib.ROLE_ID
local ENEMY_LAYOUT_TYPE = lib.ENEMY_LAYOUT_TYPE

local QUEST_ENEMY_SPAWNS = {
    { -- 影蜘蛛 A(欧米茄 SpAtk 召唤用, 参数照抄 st402_SubBoss_Ms730025 节点 / 自制 pog 实测值)
        _EmID = -1363370496, -- EM0070_00_0
        _RoleID = ROLE_ID.ROLE_COLLAB_01,
        _OptionTag = 1,
        _StoryTargetID = 10, -- 对齐 _SubBossInfoArray._EmTargetID
        _Position = { -2.297, 0.426, 73.488 },                      -- 竞技场中心(pog 实测位置)
        _DifficultyRankId = "f326f227-c0ff-47bb-92e7-aa187d61ad3c", -- Ms630007 蜘蛛节点难度
        _AdvancedSettings = { _IsDefaultDeepSleep = true },
    },
    { -- 影蜘蛛 B(同上, 站位不同)
        _EmID = -1363370496, -- EM0070_00_0
        _RoleID = ROLE_ID.ROLE_COLLAB_01,
        _OptionTag = 1,
        _StoryTargetID = 11,
        _Position = { 24.183, -0.323, 92.306 },                     -- 实测坐标
        _DifficultyRankId = "f326f227-c0ff-47bb-92e7-aa187d61ad3c",
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

-- ==================== 6. 台词 NPC ====================
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

-- ==================== 7. 普通地面龙乳结晶 ====================
do
    -- 让原本受地面条件限制的招式也能请求生成龙乳结晶（GM651）。
    -- 此处只调整生成条件，不改结晶自身的命中、拘束或其他行为参数。
    -- 依据：createEnergyCrystal 原版先查询 SENSOR_GET，再要求 SensorParamGm / GM650。
    -- 这里直接执行后续 requestSetLimeStone；不依赖查询命中数，也不读取错误类型字段。
    -- 保留上游贴地、敌人主控检查，以及原始位置、方向、ownerKey、option、创建回调。
    -- hook 由任务独立 ScriptState 托管，任务结束自动摘除；不要放入 autorun。

    print("[crystal] script loading; quest_id=%s", tostring(quest.quest_id))
    assert(quest.quest_id == 10099, "10099.lua must run in quest 10099")

    local create_crystal = sdk.find_type_definition("app.cEnemyDepletionCondition"):get_method("createEnergyCrystal")
    local request_crystal = sdk.find_type_definition("app.cLimeStoneManager"):get_method("requestSetLimeStone")
    local GM651 = sdk.find_type_definition("app.GimmickDef.ID"):get_field("GM651_000_00"):get_data(nil)
    local INVALID_ITEM = sdk.find_type_definition("app.ItemDef.ID"):get_field("INVALID"):get_data(nil)

    sdk.hook(create_crystal,
        function(args)
            -- args[1]=vmctx, args[2]=app.cEnemyDepletionCondition。
            -- 三个值类型参数在 ABI 中以地址传入；只在当前 pre 回调中使用。
            local position = sdk.to_valuetype(args[3], "via.vec3")
            local rotation = sdk.to_valuetype(args[4], "via.Quaternion")
            local owner_key = sdk.to_valuetype(args[5], "app.TARGET_ACCESS_KEY")
            local option = (sdk.to_int64(args[6]) & 0xFF) ~= 0
            local callback = sdk.to_managed_object(args[7]) -- System.Action<via.GameObject>
            local manager = sdk.get_managed_singleton("app.GimmickManager"):call("get_LimeStoneManager()")

            local result = request_crystal:call(manager, GM651, position, rotation, owner_key, callback, -1, option, true, false, 0, INVALID_ITEM)
            -- 保留请求失败时的上游重试机会；true 表示请求接受，不是异步实例化完成。
            thread.get_hook_storage().crystal_requested = result ~= nil
            print("[crystal] result=%s", tostring(result ~= nil))
            return sdk.PreHookResult.SKIP_ORIGINAL
        end,
        function(retval)
            return sdk.to_ptr(thread.get_hook_storage().crystal_requested and 1 or 0)
        end)

    print("[crystal] hook registered; create=%s request=%s", tostring(create_crystal:get_function()), tostring(request_crystal:get_function()))
end

-- 欧米茄大招：同步10098当前配置，局部作用域不影响本任务其他功能。
do
-- ==================== 8. 大招配置 ====================
-- 起飞/无罩激光与爆炸共用中心; CHARGE_POS用于原生绕飞目标，不直接设置怪物Transform。
-- 原生 loadArgmentData 在非 ST402 会将 StartPos 清为世界原点, 因此必须 post 写回。
-- Nullable<via.vec3> 修改后写回整个字段; 此方式已经临时 ShootingInfo 对象往返验证。
local ATTACK_CENTER = Vector3f.new(-6.099601, 5, 98.362564)
-- local CHARGE_POS = Vector3f.new(-42.243317, 5, 99.290459)
local CHARGE_POS = Vector3f.new(-32.265949, 5, 98.130585)
local BURST_SCALE = 1.5 -- 整体缩放: 原版半径42/端点Z=±30 -> 半径63/端点Z=±45
local BURST_YAW = math.atan(ATTACK_CENTER.x - CHARGE_POS.x, ATTACK_CENTER.z - CHARGE_POS.z)
local BURST_ROTATION = Quaternion.new(math.cos(BURST_YAW / 2), 0, math.sin(BURST_YAW / 2), 0)

-- 8.1 爆炸出生参数: 仅Creator 47 / Shell 26; 不改激光、伤害或EffectScale。
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

-- 8.2 跨场景getter修正: 非ST402原生返回固定中心或相对蓄力坐标。
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


-- 8.3 小欧米茄运行时落点：不修改共享参数或召唤数组。
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

-- ==================== 9. 绕飞动画混合基准（试验） ====================
-- 原生blend使用106.533996度基准；本实现保存进入朝向，在doEnter post再次写入新blend。
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
end

-- ==================== 10. 生命周期 ====================
-- 兜底: package 卸载若发生在脚本摘钩之后, 这里把还没还原的一次性还原
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

-- 任务 flow 变化只打印阶段名, 观察任务流程用
quest.on_flow_changed(function(flow)
    print("flow: %s", flow)
end)

quest.on_unload(function()
    for id in pairs(motion_speed_patched) do
        restore_motion_speed_patch(id)
    end
    restore_slip_lifetime()
    restore_rampage_rate()
    lib.unload_mission_dialogues(OMEGA_MISSION_FIXED)
    print("unloading quest script, hooks will be removed")
end)
