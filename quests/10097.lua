-- 任务 10097：王锁强化任务机制。包含解放门槛、翼刃积蓄倍率、龙乳结晶及控制效果免疫。
-- 依据：createEnergyCrystal 原版先查询 SENSOR_GET，再要求 SensorParamGm / GM650。
-- 这里直接执行后续 requestSetLimeStone；不依赖查询命中数，也不读取错误类型字段。
-- 保留上游贴地、敌人主控检查，以及原始位置、方向、ownerKey、option、创建回调。
-- hook 由任务独立 ScriptState 托管，任务结束自动摘除；不要放入 autorun。

-- 功能块:
--   1. 王锁参数       package加载时调整血量门槛、翼刃积蓄及王锁动作速度，卸载时还原
--   2. 龙乳结晶     普通地面生成GM651，仅王锁愤怒时固定龙属性自动激活
--   3. 控制免疫     王锁不受闪光、诱导弹及各类陷阱影响
--   4. 王锁开局解放 doStartBegin后直接设为UNLEASH

local lib = require("scripts.quest_lib")
local print = lib.print

assert(quest.quest_id == 10097, "10097.lua must run in quest 10097")

-- 生命周期只记录一次；registered是注册完成，applied/restored才表示实际修改/恢复。
print("----------------------------------------------------------------")

-- ==================== 1. 王锁参数配置 ====================
do
    -- 两项均为严格 HP% < 阈值：100表示掉血后生效，满血不满足。
    -- 只调整门槛，不直接改Mode，也不改自动充能量或计时周期。
    local UNLEASH_MODE_CHANGE_THRESHOLD = 100.0
    local AUTO_ELEMENT_CHARGE_ACCELERATION_THRESHOLD = 100.0
    -- 原版两项均约为1.1111；设为1.0后，玩家/NPC翼刃积蓄约为原版90%。
    local PL_GALIAN_RATE_KING = 1.0
    local NPC_GALIAN_RATE_KING = 1.0
    local KING_MOTION_SPEED = 1.15
    local EM0160_00_0 = 27 -- EnemyDef.ID，运行时ID
    local param, original_unleash, original_acceleration, original_pl_galian, original_npc_galian
    local legendary, original_motion_speed_hard

    lib.on_enemy_package(EM0160_00_0, function(id)
        -- 按任务约定 package 就绪时 StageResident 已就绪；原生判定读基类 Genus，不是 Species。
        local resident = sdk.get_managed_singleton("app.EnemyManager"):call("getEnemyStageResident(app.EnemyDef.ID)", id)
        param = resident:get_field("_Unique"):get_field("_GenusInfo")
        original_unleash = param:get_field("UnleashModeChangeThreshold")
        original_acceleration = param:get_field("AutoElementChargeAccelerationThreshold")
        original_pl_galian = param:get_field("PLGalianRate_King")
        original_npc_galian = param:get_field("NPCGalianRate_King")
        param:set_field("UnleashModeChangeThreshold", UNLEASH_MODE_CHANGE_THRESHOLD)
        param:set_field("AutoElementChargeAccelerationThreshold", AUTO_ELEMENT_CHARGE_ACCELERATION_THRESHOLD)
        param:set_field("PLGalianRate_King", PL_GALIAN_RATE_KING)
        param:set_field("NPCGalianRate_King", NPC_GALIAN_RATE_KING)
        print("[king-param] applied; enemy_id=%d; UnleashModeChangeThreshold=%g -> %g; AutoElementChargeAccelerationThreshold=%g -> %g; PLGalianRate_King=%g -> %g; NPCGalianRate_King=%g -> %g",
            id, original_unleash, param:get_field("UnleashModeChangeThreshold"),
            original_acceleration, param:get_field("AutoElementChargeAccelerationThreshold"),
            original_pl_galian, param:get_field("PLGalianRate_King"),
            original_npc_galian, param:get_field("NPCGalianRate_King"))

        -- 本任务只有王锁，直接调整当前生效的Hard倍率，不动King覆盖开关。
        legendary = sdk.get_managed_singleton("app.EnemyManager"):call("getPackage(app.EnemyDef.ID)", id)
            :get_field("_ParamPack"):get_field("_Legendary")
        original_motion_speed_hard = legendary:get_field("MotionSpeedRate_Hard")
        legendary:set_field("MotionSpeedRate_Hard", KING_MOTION_SPEED)
        print("[king-speed] applied; MotionSpeedRate_Hard=%g -> %g",
            original_motion_speed_hard, legendary:get_field("MotionSpeedRate_Hard"))
    end, function()
        if legendary ~= nil then
            legendary:set_field("MotionSpeedRate_Hard", original_motion_speed_hard)
            print("[king-speed] restored; MotionSpeedRate_Hard=%g", original_motion_speed_hard)
            legendary = nil
        end
        if param == nil then return end
        param:set_field("UnleashModeChangeThreshold", original_unleash)
        param:set_field("AutoElementChargeAccelerationThreshold", original_acceleration)
        param:set_field("PLGalianRate_King", original_pl_galian)
        param:set_field("NPCGalianRate_King", original_npc_galian)
        print("[king-param] restored; unleash=%g acceleration=%g pl_galian=%g npc_galian=%g",
            param:get_field("UnleashModeChangeThreshold"), param:get_field("AutoElementChargeAccelerationThreshold"),
            param:get_field("PLGalianRate_King"), param:get_field("NPCGalianRate_King"))
        param = nil
    end)
    print("[king-param] registered; waiting=package-load; enemy_id=%d; target_unleash=%g target_acceleration=%g target_pl_galian=%g target_npc_galian=%g",
        EM0160_00_0, UNLEASH_MODE_CHANGE_THRESHOLD, AUTO_ELEMENT_CHARGE_ACCELERATION_THRESHOLD,
        PL_GALIAN_RATE_KING, NPC_GALIAN_RATE_KING)
    print("[king-speed] registered; waiting=package-load; MotionSpeedRate_Hard=%g", KING_MOTION_SPEED)

    -- 参数恢复统一走 unloaded；任务结束时由 lib 检查驻留包并补发。
end

-- ==================== 2. 龙乳结晶 ====================

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
        return sdk.PreHookResult.SKIP_ORIGINAL
    end,
    function(retval)
        return sdk.to_ptr(thread.get_hook_storage().crystal_requested and 1 or 0)
    end)

print("[crystal] registered; sensor_requirement=disabled; waiting=createEnergyCrystal; create=%s request=%s", tostring(create_crystal:get_function()), tostring(request_crystal:get_function()))

-- 新结晶初始化结束时检查创建者是否愤怒：愤怒才用龙属性自动激活。
-- 非愤怒保留普通结晶，可正常受击激活；不轮询，不追溯处理已有结晶。
-- 本任务结晶均由王锁创建；owner用于愤怒判定和原生伤害归属。
do
    local gm_type = sdk.find_type_definition("app.Gm651")
    local start = gm_type:get_method("doStartEnd()")
    local damage = gm_type:get_method("damageEvent()")
    local resolve_owner = sdk.find_type_definition("app.TargetAccessKeyUtil"):get_method("getEnemyManageInfo")
    local DRAGON = sdk.find_type_definition("app.HitDef.ATTR"):get_field("DRAGON"):get_data(nil)

    sdk.hook(start, function(args)
        thread.get_hook_storage().new_crystal = sdk.to_managed_object(args[2])
    end, function(retval)
        local crystal = thread.get_hook_storage().new_crystal
        local context = crystal:call("get_GimmickContext()")
        if not context:call("get_IsMaster()") or crystal:get_field("_EnableExplosion") then return retval end

        local owner = resolve_owner:call(nil, context:call("get_RequestSetOwnerKey()"), false)
        local owner_object = owner and owner:call("get_Object()")
        if owner_object == nil then return retval end
        local angry = owner:call("get_Context()"):get_field("_Em"):call("get_IsAngry()")
        if not angry then return retval end
        local info = sdk.create_instance("app.cGimmickDamageInfo"):add_ref()
        info:call(".ctor()")
        info:set_field("_Attribute", DRAGON)
        info:set_field("_AttackerObj", owner_object)
        info:set_field("_ActualAttackerObj", owner_object)

        -- damageEvent无HitInfo参数，直接写入其读取的ApplyDamageInfo，不恢复旧值。
        -- 不清空积蓄列表，不扣结晶血量；原函数负责预兆、碰撞关闭、归属和发包。
        local stock = crystal:get_field("_BreakMiniComponent"):get_field("_StockDamage")
        stock:set_field("_ApplyDamageInfo", info)
        damage:call(crystal)
        return retval
    end)
    print("[crystal-auto] registered; trigger=doStartEnd; angry_only=true; attribute=DRAGON; master_only=true; start=%s",
        tostring(start:get_function()))
end

-- ==================== 3. 闪光/诱导弹/陷阱免疫 ====================
-- 原版按EmParamBadCondition2.EnemyBadConditionSetting中的预设GUID初始化条件对象。
-- GUID为零时查不到预设，条件不会成为有效条件；巨戟龙、白炽龙等原版免疫怪也采用此配置。
-- 在敌人包初始化前清空Em0160对应字段，卸载时还原；不再逐帧请求NO_ACTIVATE。
do
    local EM0160_00_0 = 27 -- EnemyDef.ID，运行时ID
    local BOSS = 0          -- app.EnemyDef.CATEGORY.BOSS
    local disabled_fields = {
        -- King会优先读取FlashKingPriset；不动普通个体使用的FlashPriset。
        "FlashKingPriset",
        "EmLeadPreset",
        "TrapFallPriset",
        "TrapParalysePriset",
        "TrapIvyPriset",
        "TrapParalyseAnimalPriset",
        "TrapParalyseOtomoPriset",
        "TrapBoundNPCPriset",
    }
    local bad_condition_setting
    local original_guids = {}
    local zero_guid = ValueType.new(sdk.find_type_definition("System.Guid"))

    -- MMDK/EMV Engine使用的通用ValueType字段写法：动态取字段偏移，
    -- 并且只拷贝get_valuetype_size()字节，避免System.Guid的32/16字节尺寸差。
    local function write_valuetype(parent_obj, field_name, value)
        local offset = parent_obj:get_type_definition():get_field(field_name):get_offset_from_base()
        for i = 0, value.type:get_valuetype_size() - 1 do
            parent_obj:write_byte(offset + i, value:read_byte(i))
        end
    end

    lib.on_enemy_package(EM0160_00_0, function(id)
        local enemy_setting = sdk.get_managed_singleton("app.EnemyManager"):call("get_Setting()")
        local bad_condition2 = enemy_setting:call("get_BadCondition2()")
        bad_condition_setting = bad_condition2:call(
            "getBadConditionPriset(app.EnemyDef.ID, app.EnemyDef.CATEGORY)", id, BOSS)
        assert(bad_condition_setting ~= nil, "Em0160 bad-condition setting not found")

        for _, field_name in ipairs(disabled_fields) do
            local wrapper = bad_condition_setting:get_field(field_name)
            assert(wrapper ~= nil, field_name .. " wrapper not found")
            original_guids[field_name] = wrapper:get_field("Value")
            write_valuetype(wrapper, "Value", zero_guid)
        end
        print("[control-immunity] applied; enemy_id=%d; disabled_presets=%s",
            id, table.concat(disabled_fields, ","))
    end, function()
        if bad_condition_setting == nil then return end
        for _, field_name in ipairs(disabled_fields) do
            local original = original_guids[field_name]
            if original ~= nil then
                local wrapper = bad_condition_setting:get_field(field_name)
                write_valuetype(wrapper, "Value", original)
            end
        end
        print("[control-immunity] restored; presets=%s", table.concat(disabled_fields, ","))
        bad_condition_setting = nil
        original_guids = {}
    end)
    print("[control-immunity] registered; waiting=package-load; enemy_id=%d; preset_count=%d; flash=true em_lead=true traps=true", EM0160_00_0, #disabled_fields)
end

-- ==================== 4. 王锁开局解放 ====================
-- 原生初始化完成后直接写入UNLEASH；同时保留第1节的血量门槛配置。
do
    -- 本任务只有一只王锁；在原生初始化完成后直接设置实际形态，不等血量或护龙吼。
    -- UNLEASH=1 已核对运行时枚举；后续 doUpdateBegin 按此状态启用解放动作过滤器。
    -- 只在 doStartBegin post 写入，不每帧锁定，也不调用会恢复伤口的 unleash()。
    -- hook 由任务 ScriptState 托管，任务结束自动摘除。
    local start = sdk.find_type_definition("app.cEm0160Extend"):get_method("doStartBegin()")
    sdk.hook(start,
        function(args)
            thread.get_hook_storage().extend = sdk.to_managed_object(args[2])
        end,
        function(retval)
            local extend = thread.get_hook_storage().extend
            local mode = extend:get_field("_Mode")
            extend:set_field("_Mode", 1) -- app.cEm0160Extend.MODE.UNLEASH
            print("[unleash] applied; trigger=doStartBegin; mode=%d -> %d (UNLEASH)", mode, extend:get_field("_Mode"))
            return retval
        end)
    print("[unleash] registered; waiting=doStartBegin; target_mode=UNLEASH; start=%s", tostring(start:get_function()))
end

-- 在lib的参数恢复回调之后记录；hook由任务ScriptState销毁时统一摘除。
quest.on_unload(function()
    print("[lifecycle] unload callback reached; releasing quest script")
end)
print("[lifecycle] registration complete; runtime changes are logged as applied")
