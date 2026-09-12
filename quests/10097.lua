-- 任务 10097：王锁强化任务机制。包含解放门槛、龙乳结晶、龙属性翼刃炸膛及控制效果免疫。
-- 依据：createEnergyCrystal 原版先查询 SENSOR_GET，再要求 SensorParamGm / GM650。
-- 这里直接执行后续 requestSetLimeStone；不依赖查询命中数，也不读取错误类型字段。
-- 保留上游贴地、敌人主控检查，以及原始位置、方向、ownerKey、option、创建回调。
-- hook 由任务独立 ScriptState 托管，任务结束自动摘除；不要放入 autorun。

-- 功能块:
--   1. 王锁参数       package加载时调整血量门槛和玩家/NPC翼刃积蓄倍率，卸载时还原
--   2. 龙乳结晶     普通地面也能生成GM651结晶
--   3. 翼刃炸膛     King MultiParts[3/4] 仅龙属性可累计
--   4. 控制免疫     王锁不受闪光、诱导弹及各类陷阱影响
--   5. 王锁开局解放 doStartBegin后直接设为UNLEASH

local lib = require("scripts.quest_lib")
local print = lib.print

assert(quest.quest_id == 10097, "10097.lua must run in quest 10097")

-- ==================== 1. 王锁参数配置 ====================
do
    -- 两项均为严格 HP% < 阈值：100表示掉血后生效，满血不满足。
    -- 只调整门槛，不直接改Mode，也不改自动充能量或计时周期。
    local UNLEASH_MODE_CHANGE_THRESHOLD = 100.0
    local AUTO_ELEMENT_CHARGE_ACCELERATION_THRESHOLD = 100.0
    -- 原版两项均约为1.1111；降到0.5后，玩家/NPC每击写入翼刃槽的积蓄约为原版45%。
    local PL_GALIAN_RATE_KING = 0.5
    local NPC_GALIAN_RATE_KING = 0.5
    local EM0160_00_0 = 27 -- EnemyDef.ID，运行时ID
    local param, original_unleash, original_acceleration, original_pl_galian, original_npc_galian

    print("[king-param] script loading; unleash=%g acceleration=%g pl_galian=%g npc_galian=%g",
        UNLEASH_MODE_CHANGE_THRESHOLD, AUTO_ELEMENT_CHARGE_ACCELERATION_THRESHOLD,
        PL_GALIAN_RATE_KING, NPC_GALIAN_RATE_KING)
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
        print("[king-param] package loaded; enemy_id=%d; UnleashModeChangeThreshold=%g -> %g; AutoElementChargeAccelerationThreshold=%g -> %g; PLGalianRate_King=%g -> %g; NPCGalianRate_King=%g -> %g",
            id, original_unleash, param:get_field("UnleashModeChangeThreshold"),
            original_acceleration, param:get_field("AutoElementChargeAccelerationThreshold"),
            original_pl_galian, param:get_field("PLGalianRate_King"),
            original_npc_galian, param:get_field("NPCGalianRate_King"))
    end, function()
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
    print("[king-param] package callbacks registered; enemy_id=%d", EM0160_00_0)

    -- 参数恢复统一走 unloaded；任务结束时由 lib 检查驻留包并补发。
end

-- ==================== 2. 龙乳结晶 ====================

print("[crystal] script loading; quest_id=%s", tostring(quest.quest_id))

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

print("[crystal] hook registered; create=%s request=%s", tostring(create_crystal:get_function()), tostring(request_crystal:get_function()))

-- ==================== 3. 翼刃炸膛仅限龙属性 ====================
-- 原版只过滤 AttackAttr.NONE；火/水/雷/冰/龙都会累计 King MultiParts[3/4]。
-- 这里保留原版返回值，仅把左右翼刃槽的非龙属性结果覆盖为 NO_STOCK。
do
    local KING_GALIAN_LEFT = 3
    local KING_GALIAN_RIGHT = 4
    local KING = sdk.find_type_definition("app.EnemyDef.LEGENDARY_ID"):get_field("KING"):get_data(nil)
    local DRAGON = sdk.find_type_definition("app.HitDef.ATTR"):get_field("DRAGON"):get_data(nil)
    local NO_STOCK = sdk.find_type_definition("app.EnemyDef.Damage.MULTI_PARTS_STOCK_TYPE"):get_field("NO_STOCK"):get_data(nil)
    local get_stock_type = sdk.find_type_definition("app.cEm0160Extend"):get_method("getMultiPartsStockType")

    print("[galian-dragon-only] script loading; king=%d dragon_attr=%d no_stock=%d", KING, DRAGON, NO_STOCK)
    sdk.hook(get_stock_type,
        function(args)
            -- args[3]=MultiParts索引；args[5]是cPreCalcDamage&引用槽，先解引用一次。
            local multi_parts_index = sdk.to_int64(args[3])
            if multi_parts_index ~= KING_GALIAN_LEFT and multi_parts_index ~= KING_GALIAN_RIGHT then
                return
            end

            local extend = sdk.to_managed_object(args[2])
            local context = extend:call("get_Context()"):call("get_Em()")
            if context:get_field("Basic"):get_field("LegendaryID") ~= KING then
                return
            end

            local damage_ptr = sdk.to_valuetype(args[5], "System.UInt64"):get_field("m_value")
            local damage = sdk.to_managed_object(damage_ptr)
            local attack_attr = damage:get_field("AttackAttr")
            thread.get_hook_storage().reject_galian_damage = attack_attr ~= DRAGON
        end,
        function(retval)
            if thread.get_hook_storage().reject_galian_damage then
                return sdk.to_ptr(NO_STOCK)
            end
            return retval
        end)
end

-- ==================== 4. 闪光/诱导弹/陷阱免疫 ====================
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

    print("[control-immunity] script loading; mode=bad-condition-preset flash=true em_lead=true traps=true")
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
        print("[control-immunity] presets disabled; enemy_id=%d; fields=%s",
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
        print("[control-immunity] presets restored; fields=%s", table.concat(disabled_fields, ","))
        bad_condition_setting = nil
        original_guids = {}
    end)
    print("[control-immunity] package callbacks registered; enemy_id=%d", EM0160_00_0)
end

-- ==================== 5. 王锁开局解放 ====================
-- 原生初始化完成后直接写入UNLEASH；同时保留第1节的血量门槛配置。
do
    -- 本任务只有一只王锁；在原生初始化完成后直接设置实际形态，不等血量或护龙吼。
    -- UNLEASH=1 已核对运行时枚举；后续 doUpdateBegin 按此状态启用解放动作过滤器。
    -- 只在 doStartBegin post 写入，不每帧锁定，也不调用会恢复伤口的 unleash()。
    -- hook 由任务 ScriptState 托管，任务结束自动摘除。
    print("[unleash] script loading; quest_id=%s", tostring(quest.quest_id))
    local start = sdk.find_type_definition("app.cEm0160Extend"):get_method("doStartBegin()")
    sdk.hook(start,
        function(args)
            thread.get_hook_storage().extend = sdk.to_managed_object(args[2])
        end,
        function(retval)
            local extend = thread.get_hook_storage().extend
            local mode = extend:get_field("_Mode")
            extend:set_field("_Mode", 1) -- app.cEm0160Extend.MODE.UNLEASH
            print("[unleash] initial mode=%d -> %d (UNLEASH)", mode, extend:get_field("_Mode"))
            return retval
        end)
    print("[unleash] hook registered; start=%s", tostring(start:get_function()))
end

