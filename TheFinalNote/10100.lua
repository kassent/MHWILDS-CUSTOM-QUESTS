-- 10100：十星巨戟龙，满血最终阶段开局。仅由 PermanentEventQuest 任务宿主加载。
-- 难度行 Health=18（默认单人180000），引用原生多人表；任务结束恢复共享资源。
-- 与10099一致：包加载时将 Legendary 的普通/Hard 动作倍率设为1.2，卸载还原。
-- 地面60秒/飞行80秒；DPS窗口180秒，Strong首轮及后续SUCCESS22.5%/GREAT45%。
-- FinalHelthRate=101：原生 Area 2 阶段保险切到 FINAL 时保持满血。
-- Start 仅请求弃炮；阶段切换、怒气和龙热初始化交给原生流程。
-- TU5 静态依据：updatePhaseInsurance 147CD69A0；forceChangePhase 147CD6B10。
-- 四名 EXTRA 猎人由 createExtraPartner_Ex02Mission 创建；23800 的原生豁免不随复制继承。

local lib = require("scripts.quest_lib")
local print = lib.print

local EM0078 = 12
local QUEST_DIFFICULTY_GUID = "a80891b3-54b8-4910-bce7-cac155784c2a"
local MULTIPLAYER_TABLE_GUID = "148912cc-e71c-4088-a195-7db49568ebcd"

-- 备份读取前检查旧REFramework的抽象基类字段偏移；定长写入使用公共lib。
local MULTI_VALUE_OFFSET = sdk.find_type_definition("app.cEmParamGuid_Difficulty2_MultiRateTbl")
    :get_field("Value"):get_offset_from_base()
assert(MULTI_VALUE_OFFSET == 0x10, "REFramework Guid field offset mismatch; update REFramework")
-- 共享难度行属于任务级资源，不随敌人包卸载；GUID备份存字符串而非可变视图。
local difficulty_param, original_multiplayer_table_ref, original_health_multiplier, original_multiplayer_table_guid

quest.on_load(function()
    local difficulty_settings = sdk.get_managed_singleton("app.EnemyManager"):get_field("_Setting"):get_field("_Difficulty2")
    local quest_difficulty = difficulty_settings:call("getDifficultyRate(System.Guid)", lib.parse_guid(QUEST_DIFFICULTY_GUID))
    assert(quest_difficulty:call("get_InstanceGuid"):call("ToString") == QUEST_DIFFICULTY_GUID, "difficulty lookup returned a default row")
    -- 多人GUID已离线核对，直接替换引用；先备份，退出还原。
    local multiplayer_table_ref = quest_difficulty:get_field("_MultiTableId")
    local health_multiplier = quest_difficulty:get_field("_Health")
    local multiplayer_table_guid = multiplayer_table_ref:get_field("Value"):call("ToString")
    local target_multiplayer_table_guid = lib.parse_guid(MULTIPLAYER_TABLE_GUID)
    difficulty_param, original_multiplayer_table_ref, original_health_multiplier, original_multiplayer_table_guid =
        quest_difficulty, multiplayer_table_ref, health_multiplier, multiplayer_table_guid
    quest_difficulty:set_field("_Health", 18)
    lib.write_valuetype(multiplayer_table_ref, "Value", target_multiplayer_table_guid)
    print("[difficulty] Health %g -> 18; multi %s -> %s", health_multiplier, multiplayer_table_guid, MULTIPLAYER_TABLE_GUID)
end)

quest.on_unload(function()
    if difficulty_param == nil then return end
    lib.write_valuetype(original_multiplayer_table_ref, "Value", lib.parse_guid(original_multiplayer_table_guid))
    difficulty_param:set_field("_MultiTableId", original_multiplayer_table_ref)
    difficulty_param:set_field("_Health", original_health_multiplier)
    print("[difficulty] restored Health=%g; multi=%s", original_health_multiplier, original_multiplayer_table_guid)
    difficulty_param = nil
end)

-- 只拦截本任务强制创建的四名 EXTRA 猎人，不改普通救援、艾露猫或特殊对话判断。
-- 无条件跳过创建；作用域和摘钩完全由任务宿主管理。
sdk.hook(sdk.find_type_definition("app.NpcPlayableCreator"):get_method("createExtraPartner_Ex02Mission"), function()
    print("[npc] skipped four forced EXTRA hunters")
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    return retval
end)

-- 参考10099动作速度块：直接替换两项倍率，不乘旧值，不写实例的瞬时速度。
local legendary_motion_param, original_motion_speed_rate, original_hard_motion_speed_rate
lib.on_enemy_package(EM0078, function(id)
    local package = sdk.get_managed_singleton("app.EnemyManager"):call("getPackage(app.EnemyDef.ID)", id)
    local legendary = package:get_field("_ParamPack"):get_field("_Legendary")
    legendary_motion_param = legendary
    original_motion_speed_rate = legendary:get_field("MotionSpeedRate")
    original_hard_motion_speed_rate = legendary:get_field("MotionSpeedRate_Hard")
    legendary:set_field("MotionSpeedRate", 1.2)
    legendary:set_field("MotionSpeedRate_Hard", 1.2)
    print("[motion-speed] normal %g -> 1.2; Hard %g -> 1.2", original_motion_speed_rate, original_hard_motion_speed_rate)
end, function()
    if legendary_motion_param == nil then return end
    legendary_motion_param:set_field("MotionSpeedRate", original_motion_speed_rate)
    legendary_motion_param:set_field("MotionSpeedRate_Hard", original_hard_motion_speed_rate)
    print("[motion-speed] restored normal=%g; Hard=%g", original_motion_speed_rate, original_hard_motion_speed_rate)
    legendary_motion_param = nil
end)

-- 与 10099 的参数块一致：包加载时修改，卸载时还原；任务退出补发由 lib 负责。
-- onExtensionSetup @147CCB7D0 确认 ParamUnique 引用 StageResident._Unique._SpeciesInfo。
local common, original_common
local common_values = {
    FinalHelthRate = 101, FourTimer = 60, SixTimer = 60, FlyTimer = 80, DPSTimer = 180,
    DPSSuccessRateStrong = 22.5, DPSSuccessRateStrongSecound = 22.5,
    DPSGreatRateStrong = 45, DPSGreatRateStrongSecound = 45,
}

lib.on_enemy_package(EM0078, function(id)
    local manager = sdk.get_managed_singleton("app.EnemyManager")
    local resident = manager:call("getEnemyStageResident(app.EnemyDef.ID)", id)
    local param = resident:get_field("_Unique"):get_field("_SpeciesInfo"):get_field("_Info"):get_field("Common")
    local snapshot = {}
    for field in pairs(common_values) do snapshot[field] = param:get_field(field) end
    common, original_common = param, snapshot
    for field, value in pairs(common_values) do param:set_field(field, value) end
    print("[common] FINAL=101; ground=60; fly=80; DPS=180; SUCCESS=22.5%%; GREAT=45%%")
end, function()
    if common == nil then return end
    for field, value in pairs(original_common) do common:set_field(field, value) end
    print("[common] restored all nine tuned fields")
    common, original_common = nil, nil
end)

-- Start 后置仅请求弃炮，不强制切阶段，也不主动开启龙热/DPS。
sdk.hook(sdk.find_type_definition("app.cEm0078_00Extend"):get_method("doStartBegin"), function(args)
    local storage = thread.get_hook_storage()
    storage.railgun_start = sdk.to_managed_object(args[2])
end, function(retval)
    local storage = thread.get_hook_storage()
    local extend = storage.railgun_start
    if extend == nil or common == nil or difficulty_param == nil then return retval end
    -- 中途加入保留原生同步状态，不重放开局弃炮。
    if lib.is_late_join() then return retval end

    -- 原生弃炮不依赖 FINAL；道具未就绪时由原生缓存请求。
    -- 不伪造背部破坏，也不依赖道具飞向炮位的启用消息。
    extend:call("disposeRailgun()")
    print("[railgun] startup disposal requested")
    return retval
end)

-- 敌人开路时 Gm575 若尚未加载，原生会先置 flag，随后不重试。
-- 因此在真正的营地通道机关初始化结束后，再请求一次开路；不是每帧轮询。
sdk.hook(sdk.find_type_definition("app.Gm575_000"):get_method("doStartEnd"), nil, function(retval)
    local gm = sdk.get_managed_singleton("app.GimmickManager")
    local stage = gm and gm:call("get_St405GmManager")
    if stage ~= nil then
        stage:call("requestOpenPorterRoute")
        print("Gm575 initialized; porter route open requested")
    end
    return retval
end)

-- 炮台位置/朝向固定为当前游戏炮台的实测快照，不实时跟随玩家。
-- UniqueIndex 来自原版 ST405 布局；保留另一门炮，避免破坏原生双炮引用。
local FINAL_CANNON_UNIQUE_INDEX = 3411969
local final_cannon
local cannon_rotation_param, original_max_angle_degree
local cable_positions = {
    [3411972] = { 1060.009765625, 43.464111328125, -348.5008544921875 },
    [3411971] = { 1127.9930419921875, 43.542789459228516, -374.02987670898438 },
    [3411973] = { 1081.970947265625, 45.640598297119141, -365.02554321289062 },
}
local initialized_cables = {}

-- 炮台 ENABLE 会访问并启用三根电缆，等它们各自 Start 完成后再走原生状态切换。
-- 仅由四个对象的 Start 事件调用，兼容不同加载顺序；不轮询、不补满充能。
local function enable_final_cannon()
    if final_cannon == nil or not initialized_cables[3411972]
        or not initialized_cables[3411971] or not initialized_cables[3411973] then return end
    -- 同步副本/中途加入保留原生网络状态，位置在每个客户端本地初始化。
    if lib.is_late_join() then return end
    local cannon_context = final_cannon:call("get_ContextHolder")
    if not cannon_context:call("get_IsMaster") then return end
    cannon_context:call("changeState(ace.GimmickDef.BASE_STATE)", 0)
    print("[railgun] final platform cannon enabled; three cables ready")
end

sdk.hook(sdk.find_type_definition("app.Gm577"):get_method("doStartEnd"), function(args)
    thread.get_hook_storage().cannon_start = sdk.to_managed_object(args[2])
end, function(retval)
    local cannon = thread.get_hook_storage().cannon_start
    if cannon:call("get_UniqueIndex") ~= FINAL_CANNON_UNIQUE_INDEX then return retval end
    -- 左右各五档，每档仍为原生14度；该参数由两门炮共享，任务退出还原。
    -- 原生联机转向包只支持正负两档，此处仅修改本地推动范围。
    if cannon_rotation_param == nil then
        cannon_rotation_param = cannon:call("get_AaaUniqueParam()")
        original_max_angle_degree = cannon_rotation_param:get_field("_MaxAngleDegree")
        cannon_rotation_param:set_field("_MaxAngleDegree", 10)
    end
    local transform = cannon:call("get_GameObject()"):call("get_Transform()")
    transform:call("set_Position(via.vec3)",
        Vector3f.new(1098.884033203125, 44.856239318847656, -365.08169555664062))
    transform:call("set_Rotation(via.Quaternion)", Quaternion.new(0.89500218629837036, 0, -0.44606173038482666, 0))
    -- 原生推炮按 BaseAngle 计算朝向；同步基准，避免推炮时回到旧方向。
    local angle = transform:call("get_EulerAngle()")
    cannon:set_field("_DefaultAngle", angle)
    cannon:set_field("_BaseAngle", angle)
    final_cannon = cannon
    enable_final_cannon()
    return retval
end)

quest.on_unload(function()
    if cannon_rotation_param == nil then return end
    cannon_rotation_param:set_field("_MaxAngleDegree", original_max_angle_degree)
end)

sdk.hook(sdk.find_type_definition("app.Gm580"):get_method("doStartEnd"), function(args)
    thread.get_hook_storage().cable_start = sdk.to_managed_object(args[2])
end, function(retval)
    local cable = thread.get_hook_storage().cable_start
    local unique_index = cable:call("get_UniqueIndex")
    local position = cable_positions[unique_index]
    if position == nil then return retval end
    local transform = cable:call("get_GameObject()"):call("get_Transform()")
    transform:call("set_Position(via.vec3)", Vector3f.new(position[1], position[2], position[3]))
    transform:call("set_Rotation(via.Quaternion)", Quaternion.new(0.8974123597145081, 0, -0.4411926865577698, 0))
    initialized_cables[unique_index] = true
    enable_final_cannon()
    return retval
end)

-- 原生 updateSensor 限定玩家处于 st405_01，搬到最终场地后会挡掉拿取/接线。
-- 仅移除这三根电缆的区域门控；保留最短绳/约束规则和 activateSensor 的交互、裁剪检查。
sdk.hook(sdk.find_type_definition("app.Gm580"):get_method("updateSensor"), function(args)
    local cable = sdk.to_managed_object(args[2])
    if not initialized_cables[cable:call("get_UniqueIndex")]
        or cable:call("get_BaseParam"):call("get_BaseState()") ~= 0 then return end
    if cable:get_field("_IsShortest") then
        -- 绳索处于最短状态，启用传感器 0。
        cable:call("activateSensor(System.Boolean, System.UInt32)", true, 0)
    elseif not cable:call("get_IsConstPL()") and not cable:call("get_IsConstGm577()") then
        -- 绳索未连接玩家或炮台，启用传感器 1。
        cable:call("activateSensor(System.Boolean, System.UInt32)", true, 1)
    end  
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    return retval
end)

print("loaded: full-health FINAL; base HP=180000; motion-speed=1.2; native multiplayer table; ground=60/fly=80/DPS=180; forced EXTRA disabled")
