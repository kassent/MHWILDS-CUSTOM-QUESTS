-- 10100：十星巨戟龙，满血最终阶段开局。仅由 PermanentEventQuest 任务宿主加载。
-- 十星血量乘 0.4（默认 410000 -> 164000）；其余难度参数和战斗流程不改。
-- FinalHelthRate=101：满血也判定 FINAL；forceChangePhase(FINAL) 设置 (101-1)% HP。
-- 只在新生的权威实例初始化时调用一次，禁止每帧回血或给中途加入的副本回血。
-- TU5 静态依据：forceChangePhase 147CD6B10；checkChangePhase 147CD6690。
-- 四名 EXTRA 猎人由 createExtraPartner_Ex02Mission 创建；23800 的原生豁免不随复制继承。

local lib = require("scripts.quest_lib")
local print = lib.print

local FINAL = 2
local EM0078 = 12
local WAITING_SYNC_LATE_JOIN_PACKET = 12

local function method(type_name, method_name)
    local td = assert(sdk.find_type_definition(type_name), type_name)
    return assert(td:get_method(method_name), type_name .. "." .. method_name)
end

-- 只拦截本任务强制创建的四名 EXTRA 猎人，不改普通救援、艾露猫或特殊对话判断。
-- 无条件跳过创建；作用域和摘钩完全由任务宿主管理。
sdk.hook(method("app.NpcPlayableCreator", "createExtraPartner_Ex02Mission"), function()
    print("[npc] skipped four forced EXTRA hunters")
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    return retval
end)

-- 与 10099 的参数块一致：包加载时修改，卸载时还原；任务退出补发由 lib 负责。
-- onExtensionSetup @147CCB7D0 确认 ParamUnique 引用 StageResident._Unique._SpeciesInfo。
local common, original_final_health_rate
local legendary, original_health_rate

lib.on_enemy_package(EM0078, function(id)
    local manager = sdk.get_managed_singleton("app.EnemyManager")
    local package = manager:call("getPackage(app.EnemyDef.ID)", id)
    legendary = package:get_field("_ParamPack"):get_field("_Legendary")
    original_health_rate = legendary:get_field("HealthRate_King_Hard")
    legendary:set_field("HealthRate_King_Hard", original_health_rate * 0.4)
    print("[health-param] HealthRate_King_Hard %g -> %g", original_health_rate, legendary:get_field("HealthRate_King_Hard"))

    local resident = manager:call("getEnemyStageResident(app.EnemyDef.ID)", id)
    common = resident:get_field("_Unique"):get_field("_SpeciesInfo"):get_field("_Info"):get_field("Common")
    original_final_health_rate = common:get_field("FinalHelthRate")
    common:set_field("FinalHelthRate", 101)
    print("[final-param] FinalHelthRate %d -> %d", original_final_health_rate, common:get_field("FinalHelthRate"))
end, function()
    if legendary ~= nil then
        legendary:set_field("HealthRate_King_Hard", original_health_rate)
        print("[health-param] restored HealthRate_King_Hard -> %g", original_health_rate)
        legendary = nil
    end
    if common == nil then return end
    common:set_field("FinalHelthRate", original_final_health_rate)
    print("[final-param] restored FinalHelthRate -> %d", original_final_health_rate)
    common = nil
end)

-- Start 后置：原生 DPS 计时器、动作轨道和十星标志已初始化。
-- Artian 尚未就绪时 onAngryStartHeat 会缓存 GAS，原生 initalizeArtian 再应用。
-- 不挂 Update、不轮询 Artian，也不主动提前初始化 Artian。
sdk.hook(method("app.cEm0078_00Extend", "doStartBegin"), function(args)
    local storage = thread.get_hook_storage()
    storage.final_start = sdk.to_managed_object(args[2])
end, function(retval)
    local storage = thread.get_hook_storage()
    local extend = storage.final_start
    if extend == nil or common == nil then return retval end
    -- 同步副本只接收原生网络状态；之后即使迁移为权威端，也不会重跑 Start 初始化。
    if lib.is_late_join() then return retval end
    -- 玩家中途加入标志与单只怪物的同步等待/控制权是不同层级的状态。
    local ctx = extend:get_field("_Accessor"):call("get_ContextEm")
    if ctx:get_field("_FlagArray"):get_element(WAITING_SYNC_LATE_JOIN_PACKET) then return retval end
    local net = ctx:get_field("NetInfo")
    if net ~= nil and not net:call("get_IsMaster") then return retval end
    extend:set_field("_IsFinishAreaMove", true)
    extend:set_field("_IsDPSStop", false)
    extend:call("forceChangePhase(app.Em0078_00_Def.PHASE)", FINAL)
    if extend:call("get_Phase") == FINAL then
        -- 初始化六部位 GAS（未就绪则缓存）和首轮 DPS；仅在 Start 执行一次。
        extend:call("onAngryStartHeat")
        print("FINAL initialized at Start; HP=100%%; area=2; gas requested/DPS active; hill/porter route requested; strong=%s",
            tostring(extend:get_field("_IsStrong")))
    else
        log.error("[quest 10100] FINAL initialization did not complete; no repeated HP reset")
    end
    return retval
end)

-- 敌人开路时 Gm575 若尚未加载，原生会先置 flag，随后不重试。
-- 因此在真正的营地通道机关初始化结束后，再请求一次开路；不是每帧轮询。
sdk.hook(method("app.Gm575_000", "doStartEnd"), nil, function(retval)
    local gm = sdk.get_managed_singleton("app.GimmickManager")
    local stage = gm and gm:call("get_St405GmManager")
    if stage ~= nil then
        stage:call("requestOpenPorterRoute")
        print("Gm575 initialized; porter route open requested")
    end
    return retval
end)

print("loaded: full-health FINAL start; ten-star health x0.4; forced EXTRA hunters disabled; waiting=package-load")
