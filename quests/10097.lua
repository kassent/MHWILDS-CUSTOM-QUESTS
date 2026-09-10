-- 任务 10097：解放/自动充能加速血量门槛设为100%，普通地面也能生成龙乳结晶（GM651）。
-- 依据：createEnergyCrystal 原版先查询 SENSOR_GET，再要求 SensorParamGm / GM650。
-- 这里直接执行后续 requestSetLimeStone；不依赖查询命中数，也不读取错误类型字段。
-- 保留上游贴地、敌人主控检查，以及原始位置、方向、ownerKey、option、创建回调。
-- hook 由任务独立 ScriptState 托管，任务结束自动摘除；不要放入 autorun。

-- 功能块:
--   1. 王锁血量门槛 package 加载时将解放/自动充能加速门槛设为100%，卸载时还原
--   2. 龙乳结晶     普通地面也能生成GM651结晶
--   3. 王锁开局解放 停用的旧方案，仅保留注释

local lib = require("scripts.quest_lib")
local print = lib.print

assert(quest.quest_id == 10097, "10097.lua must run in quest 10097")

-- ==================== 1. 王锁血量门槛配置 ====================
do
    -- 两项均为严格 HP% < 阈值：100表示掉血后生效，满血不满足。
    -- 只调整门槛，不直接改Mode，也不改自动充能量或计时周期。
    local UNLEASH_MODE_CHANGE_THRESHOLD = 100.0
    local AUTO_ELEMENT_CHARGE_ACCELERATION_THRESHOLD = 100.0
    local EM0160_00_0 = 27 -- EnemyDef.ID，运行时ID
    local param, original_unleash, original_acceleration

    print("[thresholds] script loading; unleash=%g acceleration=%g",
        UNLEASH_MODE_CHANGE_THRESHOLD, AUTO_ELEMENT_CHARGE_ACCELERATION_THRESHOLD)
    lib.on_enemy_package_loaded(EM0160_00_0, function(id)
        -- 按任务约定 package 就绪时 StageResident 已就绪；原生判定读基类 Genus，不是 Species。
        local resident = sdk.get_managed_singleton("app.EnemyManager"):call("getEnemyStageResident(app.EnemyDef.ID)", id)
        param = resident:get_field("_Unique"):get_field("_GenusInfo")
        original_unleash = param:get_field("UnleashModeChangeThreshold")
        original_acceleration = param:get_field("AutoElementChargeAccelerationThreshold")
        param:set_field("UnleashModeChangeThreshold", UNLEASH_MODE_CHANGE_THRESHOLD)
        param:set_field("AutoElementChargeAccelerationThreshold", AUTO_ELEMENT_CHARGE_ACCELERATION_THRESHOLD)
        print("[thresholds] package loaded; enemy_id=%d; UnleashModeChangeThreshold=%g -> %g; AutoElementChargeAccelerationThreshold=%g -> %g",
            id, original_unleash, param:get_field("UnleashModeChangeThreshold"),
            original_acceleration, param:get_field("AutoElementChargeAccelerationThreshold"))
    end)
    lib.on_enemy_package_unloaded(EM0160_00_0, function()
        if param == nil then return end
        param:set_field("UnleashModeChangeThreshold", original_unleash)
        param:set_field("AutoElementChargeAccelerationThreshold", original_acceleration)
        print("[thresholds] restored; unleash=%g acceleration=%g",
            param:get_field("UnleashModeChangeThreshold"), param:get_field("AutoElementChargeAccelerationThreshold"))
        param = nil
    end)
    print("[thresholds] package callbacks registered; enemy_id=%d", EM0160_00_0)

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

-- ==================== 3. 王锁开局解放（停用） ====================
-- 暂停直接写Mode，保留旧方案；当前使用第1节的血量门槛配置。
--[=[
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
]=]
