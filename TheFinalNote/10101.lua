-- 10101：冰与火之歌；巨戟16万/DPS120秒，冻峰适配块见末尾。
-- 10101：十星巨戟龙，满血最终阶段开局。仅由 PermanentEventQuest 任务宿主加载。
-- 巨戟难度行 Health=16（默认单人160000）、PartsVital=16，引用原生多人表；任务结束恢复共享资源。
-- 与10099一致：包加载时将 Legendary 的普通/Hard 动作倍率设为1.2，卸载还原。
-- 四足/六足60秒、飞行80秒；DPS窗口120秒，Strong首轮及后续SUCCESS15%/GREAT30%（单人名义200/400 DPS）。
-- FinalHelthRate=101：原生 Area 2 阶段保险切到 FINAL 时保持满血。
-- Start 仅请求弃炮；阶段切换、怒气和龙热初始化交给原生流程。
-- TU5 静态依据：updatePhaseInsurance 147CD69A0；forceChangePhase 147CD6B10。
-- 四名 EXTRA 猎人由 createExtraPartner_Ex02Mission 创建；23800 的原生豁免不随复制继承。

local lib = require("scripts.quest_lib")
local print = lib.print

local EM0078 = 12
local EM0162 = 30 -- EnemyDef.ID；require_enemies 则使用 ID_Fixed。
local QUEST_DIFFICULTY_GUID = "a80891b3-54b8-4910-bce7-cac155784c2a"
local MULTIPLAYER_TABLE_GUID = "148912cc-e71c-4088-a195-7db49568ebcd"

-- 备份读取前检查旧REFramework的抽象基类字段偏移；定长写入使用公共lib。
local MULTIPLAYER_TABLE_GUID_OFFSET = sdk.find_type_definition("app.cEmParamGuid_Difficulty2_MultiRateTbl")
    :get_field("Value"):get_offset_from_base()
assert(MULTIPLAYER_TABLE_GUID_OFFSET == 0x10, "REFramework Guid field offset mismatch; update REFramework")
-- 共享难度行属于任务级资源，不随敌人包卸载；GUID备份存字符串而非可变视图。
local quest_difficulty_param, original_multiplayer_table_ref, original_health_multiplier, original_multiplayer_table_guid
local original_parts_vital_multiplier

quest.on_load(function()
    local difficulty_settings = sdk.get_managed_singleton("app.EnemyManager"):get_field("_Setting"):get_field("_Difficulty2")
    local quest_difficulty = difficulty_settings:call("getDifficultyRate(System.Guid)", lib.parse_guid(QUEST_DIFFICULTY_GUID))
    -- 多人GUID已离线核对，直接替换引用；先备份，退出还原。
    local multiplayer_table_ref = quest_difficulty:get_field("_MultiTableId")
    local health_multiplier = quest_difficulty:get_field("_Health")
    local parts_vital_multiplier = quest_difficulty:get_field("_PartsVital")
    local multiplayer_table_guid = multiplayer_table_ref:get_field("Value"):call("ToString")
    local target_multiplayer_table_guid = lib.parse_guid(MULTIPLAYER_TABLE_GUID)
    quest_difficulty_param, original_multiplayer_table_ref, original_health_multiplier, original_multiplayer_table_guid =
        quest_difficulty, multiplayer_table_ref, health_multiplier, multiplayer_table_guid
    original_parts_vital_multiplier = parts_vital_multiplier
    quest_difficulty:set_field("_Health", 18)
    quest_difficulty:set_field("_PartsVital", 16)
    lib.write_valuetype(multiplayer_table_ref, "Value", target_multiplayer_table_guid)
    print("[difficulty] Health %g -> 16; PartsVital %g -> 16; multi %s -> %s",
        health_multiplier, parts_vital_multiplier, multiplayer_table_guid, MULTIPLAYER_TABLE_GUID)
end)

quest.on_unload(function()
    if quest_difficulty_param == nil then return end
    lib.write_valuetype(original_multiplayer_table_ref, "Value", lib.parse_guid(original_multiplayer_table_guid))
    quest_difficulty_param:set_field("_MultiTableId", original_multiplayer_table_ref)
    quest_difficulty_param:set_field("_Health", original_health_multiplier)
    quest_difficulty_param:set_field("_PartsVital", original_parts_vital_multiplier)
    print("[difficulty] restored Health=%g; PartsVital=%g; multi=%s",
        original_health_multiplier, original_parts_vital_multiplier, original_multiplayer_table_guid)
    quest_difficulty_param = nil
end)

-- 只拦截本任务强制创建的四名 EXTRA 猎人，不改普通救援、艾露猫或特殊对话判断。
-- 无条件跳过创建；作用域和摘钩完全由任务宿主管理。
sdk.hook(sdk.find_type_definition("app.NpcPlayableCreator"):get_method("createExtraPartner_Ex02Mission"), function()
    print("[npc] skipped four forced EXTRA hunters")
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    return retval
end)

-- 巨戟或冻峰与玩家战斗时禁止主动回营；脱战、换怪间隙不强制锁营。
-- get_IsCombatPl检查当前/待切换AI状态COMBAT；其他敌人和Manager判定保持原生。
sdk.hook(sdk.find_type_definition("app.cEnemyBrowser"):get_method("isBlockedReturnCamp()"), function(args)
    local enemy_browser = sdk.to_managed_object(args[2])
    if not enemy_browser:call("get_IsContextValid()") then return end
    local enemy_id = enemy_browser:call("get_EmID()")
    if enemy_id ~= EM0078 and enemy_id ~= EM0162 then return end
    thread.get_hook_storage().boss_combat_camp_blocked = enemy_browser:call("get_IsCombatPl()")
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    local blocked = thread.get_hook_storage().boss_combat_camp_blocked
    if blocked ~= nil then return sdk.to_ptr(blocked and 1 or 0) end
    return retval
end)

-- 巨戟撤场/客户端迟加入后补齐ST405最终环境；不要求本机曾经历巨戟FINAL。
-- 各端独立写本地阶段和原生global85/86；不伪造巨戟引用，不改网络或销毁流程。
-- 场景初始化完成后才处理；任务退出由原生还原，宿主负责摘钩。
local renderer_type = sdk.find_type_definition("via.render.Renderer")
local get_environment_global_param = renderer_type:get_method("getUserGlobalParam(System.Int32)")
local set_environment_global_param = renderer_type:get_method("setUserGlobalParam(System.Int32, System.Single)")

sdk.hook(sdk.find_type_definition("app.cSt405Environment")
    :get_method("update()"), function(args)
    if sdk.get_managed_singleton("app.EnvironmentManager"):get_field("_CurrentStage") ~= 13 then return end
    local stage_environment = sdk.to_managed_object(args[2])
    if stage_environment:get_field("_Em0078") ~= nil then return end
    local environment_transition = stage_environment:get_field("_TransitionRate")
    if environment_transition == nil then return end -- init尚未完成，不写默认高度。

    local transition_height = stage_environment:get_field("_TransitionPosY")
    local final_height = transition_height:get_field("s") + transition_height:get_field("r")
    if stage_environment:get_field("_Em0078Phase") ~= 3
        or stage_environment:get_field("_Em0078PhaseBefore") ~= 3
        or get_environment_global_param:call(nil, 85) ~= 3.0
        or get_environment_global_param:call(nil, 86) ~= final_height then
        local previous_phase = stage_environment:get_field("_Em0078Phase")
        stage_environment:set_field("_Em0078Phase", 3)
        stage_environment:set_field("_Em0078PhaseBefore", 3)
        environment_transition:call("finish()")
        set_environment_global_param:call(nil, 85, 3.0)
        set_environment_global_param:call(nil, 86, final_height)
        print("[environment] ST405 local phase %d -> FINAL; global85=3/global86=%g", previous_phase, final_height)
    end
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    return retval
end)

-- 参考10099动作速度块：直接替换两项倍率，不乘旧值，不写实例的瞬时速度。
local gogmazios_legendary_param, original_gogmazios_motion_speed_rate, original_gogmazios_hard_motion_speed_rate
lib.on_enemy_package(EM0078, function(enemy_id)
    local enemy_package = sdk.get_managed_singleton("app.EnemyManager"):call("getPackage(app.EnemyDef.ID)", enemy_id)
    local legendary_param = enemy_package:get_field("_ParamPack"):get_field("_Legendary")
    gogmazios_legendary_param = legendary_param
    original_gogmazios_motion_speed_rate = legendary_param:get_field("MotionSpeedRate")
    original_gogmazios_hard_motion_speed_rate = legendary_param:get_field("MotionSpeedRate_Hard")
    legendary_param:set_field("MotionSpeedRate", 1.2)
    legendary_param:set_field("MotionSpeedRate_Hard", 1.2)
    print("[motion-speed] normal %g -> 1.2; Hard %g -> 1.2", original_gogmazios_motion_speed_rate, original_gogmazios_hard_motion_speed_rate)
end, function()
    if gogmazios_legendary_param == nil then return end
    gogmazios_legendary_param:set_field("MotionSpeedRate", original_gogmazios_motion_speed_rate)
    gogmazios_legendary_param:set_field("MotionSpeedRate_Hard", original_gogmazios_hard_motion_speed_rate)
    print("[motion-speed] restored normal=%g; Hard=%g", original_gogmazios_motion_speed_rate, original_gogmazios_hard_motion_speed_rate)
    gogmazios_legendary_param = nil
end)

-- 原版第三阶段约18万/41万的血量区间，按原生每10%一档近似映射到当前整条血量。
-- 只改巨戟普通角色的怒气倍率；上限10000、怒态时长及阶段强制进怒保持原生。
local gogmazios_angry_rates = { 1.0, 0.75, 0.75, 0.5, 0.5, 1.0, 1.0, 1.0, 1.0, 1.0 }
local gogmazios_angry_rate_array, original_gogmazios_angry_rates

lib.on_enemy_package(EM0078, function(enemy_id)
    local enemy_package = sdk.get_managed_singleton("app.EnemyManager"):call("getPackage(app.EnemyDef.ID)", enemy_id)
    local angry_param = enemy_package:get_field("_ParamPack"):get_field("_Angry")
    local angry_rate_array = angry_param:get_field("_AngryRateLevelArray")
    assert(angry_rate_array:get_size() == #gogmazios_angry_rates, "Gogmazios angry rate array size mismatch")
    local original_angry_rates = {}
    for rate_index = 1, #gogmazios_angry_rates do
        original_angry_rates[rate_index] = angry_rate_array:read_float(0x20 + (rate_index - 1) * 4)
    end
    gogmazios_angry_rate_array, original_gogmazios_angry_rates = angry_rate_array, original_angry_rates
    -- System.Single[]元素从0x20开始，每项4字节；与既有部位耐久数组写法一致。
    for rate_index, rate in ipairs(gogmazios_angry_rates) do
        angry_rate_array:write_float(0x20 + (rate_index - 1) * 4, rate)
    end
    print("[angry] rates %s -> %s",
        table.concat(original_angry_rates, "/"), table.concat(gogmazios_angry_rates, "/"))
end, function()
    if gogmazios_angry_rate_array == nil then return end
    for rate_index, rate in ipairs(original_gogmazios_angry_rates) do
        gogmazios_angry_rate_array:write_float(0x20 + (rate_index - 1) * 4, rate)
    end
    print("[angry] restored damage-to-anger rates")
    gogmazios_angry_rate_array, original_gogmazios_angry_rates = nil, nil
end)

-- 与 10099 的参数块一致：包加载时修改，卸载时还原；任务退出补发由 lib 负责。
-- onExtensionSetup @147CCB7D0 确认 ParamUnique 引用 StageResident._Unique._SpeciesInfo。
local gogmazios_common_param, original_gogmazios_common_values
local gogmazios_common_values = {
    FinalHelthRate = 101, FourTimer = 60, SixTimer = 60, FlyTimer = 80, DPSTimer = 150,
    DPSSuccessRateStrong = 15, DPSSuccessRateStrongSecound = 15,
    DPSGreatRateStrong = 30, DPSGreatRateStrongSecound = 30,
}

lib.on_enemy_package(EM0078, function(enemy_id)
    local enemy_manager = sdk.get_managed_singleton("app.EnemyManager")
    local enemy_stage_resident = enemy_manager:call("getEnemyStageResident(app.EnemyDef.ID)", enemy_id)
    local common_param = enemy_stage_resident:get_field("_Unique"):get_field("_SpeciesInfo"):get_field("_Info"):get_field("Common")
    local original_common_values = {}
    for field_name in pairs(gogmazios_common_values) do original_common_values[field_name] = common_param:get_field(field_name) end
    gogmazios_common_param, original_gogmazios_common_values = common_param, original_common_values
    for field_name, value in pairs(gogmazios_common_values) do common_param:set_field(field_name, value) end
    print("[common] FINAL=101; ground=60; fly=80; DPS=120; SUCCESS=15%%; GREAT=30%%")
end, function()
    if gogmazios_common_param == nil then return end
    for field_name, value in pairs(original_gogmazios_common_values) do gogmazios_common_param:set_field(field_name, value) end
    print("[common] restored tuned fields")
    gogmazios_common_param, original_gogmazios_common_values = nil, nil
end)

-- Start 后置仅请求弃炮，不强制切阶段，也不主动开启龙热/DPS。
sdk.hook(sdk.find_type_definition("app.cEm0078_00Extend"):get_method("doStartBegin"), function(args)
    local hook_storage = thread.get_hook_storage()
    hook_storage.railgun_start = sdk.to_managed_object(args[2])
end, function(retval)
    local hook_storage = thread.get_hook_storage()
    local gogmazios_extend = hook_storage.railgun_start
    -- 中途加入保留原生同步状态，不重放开局弃炮。
    if lib.is_late_join() then return retval end

    -- 原生弃炮不依赖 FINAL；道具未就绪时由原生缓存请求。
    -- 不伪造背部破坏，也不依赖道具飞向炮位的启用消息。
    gogmazios_extend:call("disposeRailgun()")
    print("[railgun] startup disposal requested")
    return retval
end)

-- 敌人开路时 Gm575 若尚未加载，原生会先置 flag，随后不重试。
-- 因此在真正的营地通道机关初始化结束后，再请求一次开路；不是每帧轮询。
sdk.hook(sdk.find_type_definition("app.Gm575_000"):get_method("doStartEnd"), nil, function(retval)
    local gimmick_manager = sdk.get_managed_singleton("app.GimmickManager")
    local stage_gimmick_manager = gimmick_manager and gimmick_manager:call("get_St405GmManager")
    if stage_gimmick_manager ~= nil then
        stage_gimmick_manager:call("requestOpenPorterRoute")
        print("Gm575 initialized; porter route open requested")
    end
    return retval
end)

-- 炮台位置/朝向固定为当前游戏炮台的实测快照，不实时跟随玩家。
-- UniqueIndex 来自原版 ST405 布局；保留另一门炮，避免破坏原生双炮引用。
local FINAL_CANNON_UNIQUE_INDEX = 3411969
local CANNON_MAX_STEPS = 10
local CANNON_PUSH_PACKET_BASE = 128
local cannon_rotation_param, original_cannon_max_angle_degree
local cable_positions = {
    [3411972] = { 1060.009765625, 43.464111328125, -348.5008544921875 },
    [3411971] = { 1127.9930419921875, 43.542789459228516, -374.02987670898438 },
    [3411973] = { 1081.970947265625, 45.640598297119141, -365.02554321289062 },
}

-- 实测 Playing.enter 晚于炮台/三根电缆完整 Start，在此统一启用；不轮询、不补充充能。
sdk.hook(sdk.find_type_definition("app.cQuestPlaying"):get_method("enter"), nil, function(retval)
    if lib.is_late_join() then return retval end
    local gimmick_manager = sdk.get_managed_singleton("app.GimmickManager")
    local cannon = gimmick_manager:call("findGimmick_UniqueIndex(System.Int32)", FINAL_CANNON_UNIQUE_INDEX)
    if cannon == nil then
        log.error("[quest 10101] Playing entered but cannon 3411969 was not found")
        return retval
    end
    -- 同步副本/中途加入保留原生状态，各客户端仍在 Start 初始化位置。
    local cannon_context = cannon:call("get_ContextHolder")
    if not cannon_context:call("get_IsMaster") then return retval end
    cannon_context:call("changeState(ace.GimmickDef.BASE_STATE)", 0)
    print("[railgun] final platform cannon enabled at Playing; unique=%d", FINAL_CANNON_UNIQUE_INDEX)
    return retval
end)

sdk.hook(sdk.find_type_definition("app.Gm577"):get_method("doStartEnd"), function(args)
    thread.get_hook_storage().cannon_start = sdk.to_managed_object(args[2])
end, function(retval)
    local cannon = thread.get_hook_storage().cannon_start
    if cannon:call("get_UniqueIndex") ~= FINAL_CANNON_UNIQUE_INDEX then return retval end
    -- 左右各十档，每档仍为原生14度；该参数由两门炮共享，任务退出还原。
    -- 下方扩展推动包和迟加入编码，保留每档14度及原生动画。
    if cannon_rotation_param == nil then
        cannon_rotation_param = cannon:call("get_AaaUniqueParam()")
        original_cannon_max_angle_degree = cannon_rotation_param:get_field("_MaxAngleDegree")
        cannon_rotation_param:set_field("_MaxAngleDegree", CANNON_MAX_STEPS)
    end
    local cannon_transform = cannon:call("get_GameObject()"):call("get_Transform()")
    cannon_transform:call("set_Position(via.vec3)",
        Vector3f.new(1098.884033203125, 44.856239318847656, -365.08169555664062))
    cannon_transform:call("set_Rotation(via.Quaternion)", Quaternion.new(0.89500218629837036, 0, -0.44606173038482666, 0))
    -- 原生推炮按 BaseAngle 计算朝向；同步基准，避免推炮时回到旧方向。
    local cannon_euler_angle = cannon_transform:call("get_EulerAngle()")
    cannon:set_field("_DefaultAngle", cannon_euler_angle)
    cannon:set_field("_BaseAngle", cannon_euler_angle)
    return retval
end)

quest.on_unload(function()
    if cannon_rotation_param == nil then return end
    cannon_rotation_param:set_field("_MaxAngleDegree", original_cannon_max_angle_degree)
end)

sdk.hook(sdk.find_type_definition("app.Gm580"):get_method("doStartEnd"), function(args)
    thread.get_hook_storage().cable_start = sdk.to_managed_object(args[2])
end, function(retval)
    local cable = thread.get_hook_storage().cable_start
    local cable_unique_index = cable:call("get_UniqueIndex")
    local cable_position = cable_positions[cable_unique_index]
    if cable_position == nil then return retval end
    local cable_transform = cable:call("get_GameObject()"):call("get_Transform()")
    cable_transform:call("set_Position(via.vec3)", Vector3f.new(cable_position[1], cable_position[2], cable_position[3]))
    cable_transform:call("set_Rotation(via.Quaternion)", Quaternion.new(0.8974123597145081, 0, -0.4411926865577698, 0))
    return retval
end)

-- 原生 updateSensor 限定玩家处于 st405_01，搬到最终场地后会挡掉拿取/接线。
-- 仅移除这三根电缆的区域门控；保留最短绳/约束规则和 activateSensor 的交互、裁剪检查。
sdk.hook(sdk.find_type_definition("app.Gm580"):get_method("updateSensor"), function(args)
    local cable = sdk.to_managed_object(args[2])
    if cable_positions[cable:call("get_UniqueIndex")] == nil
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

-- 两门炮共享十档参数，因此 Gm577 的两门炮都使用同一扩展协议。
-- 原生推动包 degree+3 会撞到消息6~11；只关闭本次推动的原生发送，
-- 本地动画仍由原函数执行，实际档位改变后再通过原生 sendPacket 发送128~148。
sdk.hook(sdk.find_type_definition("app.Gm577"):get_method("pushBody(System.Boolean, System.Boolean)"), function(args)
    local cannon = sdk.to_managed_object(args[2])
    thread.get_hook_storage().railgun_push = {
        cannon = cannon,
        previous_degree = cannon:get_field("_AngleDegree"),
        send_requested = (sdk.to_int64(args[4]) & 1) ~= 0,
    }
    args[4] = sdk.to_ptr(0)
end, function(retval)
    local cannon_push_state = thread.get_hook_storage().railgun_push
    local angle_degree = cannon_push_state.cannon:get_field("_AngleDegree")
    if cannon_push_state.send_requested and angle_degree ~= cannon_push_state.previous_degree then
        local gimmick_packet = sdk.create_instance("app.net_packet.cGmBase"):add_ref()
        gimmick_packet:call(".ctor()")
        cannon_push_state.cannon:set_field("_PacketFreeBuf", CANNON_PUSH_PACKET_BASE + angle_degree + CANNON_MAX_STEPS)
        -- 保留原生网络门控、可靠发送及发送后的 FreeBuf 清理。
        cannon_push_state.cannon:call("sendPacket(app.net_packet.cGmBase)", gimmick_packet)
        print("[railgun net] push degree=%d; code=%d", angle_degree,
            CANNON_PUSH_PACKET_BASE + angle_degree + CANNON_MAX_STEPS)
    end
    return retval
end)

-- 只有扩展角度包走此分支；原生接线、充能、交互等消息完整放行。
sdk.hook(sdk.find_type_definition("app.Gm577"):get_method("doReceivePacket(app.net_packet.cGmBase)"), function(args)
    local gimmick_packet = sdk.to_managed_object(args[3])
    local packet_code = gimmick_packet:get_field("_FreeBuf")
    local is_angle_packet = packet_code >= CANNON_PUSH_PACKET_BASE
        and packet_code <= CANNON_PUSH_PACKET_BASE + CANNON_MAX_STEPS * 2
    thread.get_hook_storage().railgun_angle_packet = is_angle_packet
    if not is_angle_packet then return end
    local cannon = sdk.to_managed_object(args[2])
    local angle_degree = packet_code - CANNON_PUSH_PACKET_BASE - CANNON_MAX_STEPS
    -- int 重载应用绝对档位及推动动画，不再次发送。
    cannon:call("pushBody(System.Int32)", angle_degree)
    print("[railgun net] received degree=%d; code=%d", angle_degree, packet_code)
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    if thread.get_hook_storage().railgun_angle_packet then return sdk.to_ptr(1) end
    return retval
end)

-- 迟加入快照：原生低三位角度占位，充能3~6位、禁用交互7位、电缆演出8位不变。
-- 扩展角度追加到9~13位；保持原生充能量化 floor(Power*10)。
sdk.hook(sdk.find_type_definition("app.Gm577"):get_method("onGetLateJoinSyncPacketFreeBuf"), function(args)
    thread.get_hook_storage().railgun_sync_cannon = sdk.to_managed_object(args[2])
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    local cannon = thread.get_hook_storage().railgun_sync_cannon
    if cannon:call("get_BaseParam"):call("get_BaseState()") ~= 0 then return sdk.to_ptr(0) end
    local angle_degree = cannon:get_field("_AngleDegree")
    local power_tenths = math.floor(cannon:get_field("_Power") * 10)
    local late_join_free_buf = ((angle_degree + CANNON_MAX_STEPS) << 9) | (power_tenths << 3)
    if not cannon:get_field("_IsEnableInteract") then late_join_free_buf = late_join_free_buf | (1 << 7) end
    local cable_state = cannon:get_field("_CableMotionState")
    if cable_state == 1 or cable_state == 2 then late_join_free_buf = late_join_free_buf | (1 << 8) end
    print("[railgun net] late-join snapshot degree=%d; power=%g", angle_degree, cannon:get_field("_Power"))
    return sdk.to_ptr(late_join_free_buf)
end)

sdk.hook(sdk.find_type_definition("app.Gm577"):get_method("onApplyLateJoinSyncPacket(System.Byte, System.Int16)"), function(args)
    local hook_storage = thread.get_hook_storage()
    hook_storage.railgun_apply_sync = nil
    -- 原生仅在接收状态 ENABLE(0) 时解析快照，其他状态完整放行。
    if (sdk.to_int64(args[3]) & 0xFF) ~= 0 then return end
    local late_join_free_buf = sdk.to_int64(args[4]) & 0xFFFF
    hook_storage.railgun_apply_sync = {
        cannon = sdk.to_managed_object(args[2]),
        angle_degree = ((late_join_free_buf >> 9) & 0x1F) - CANNON_MAX_STEPS,
    }
    -- 原包直接交给原函数处理充能/交互/电缆，字段不移位、不改写实参。
    -- 原生只读取低三位角度；同次调用的 post 再恢复高位中的实际角度。
end, function(retval)
    local cannon_late_join_state = thread.get_hook_storage().railgun_apply_sync
    if cannon_late_join_state == nil then return retval end
    local cannon = cannon_late_join_state.cannon
    cannon:set_field("_AngleDegree", cannon_late_join_state.angle_degree)
    local cannon_base_angle = cannon:get_field("_BaseAngle")
    local push_angle_degrees = cannon:call("get_AaaUniqueParam()"):get_field("_PushAngle")
    local cannon_transform = cannon:call("get_GameObject()"):call("get_Transform()")
    cannon_transform:call("set_EulerAngle(via.vec3)", Vector3f.new(cannon_base_angle.x,
        cannon_base_angle.y - math.rad(cannon_late_join_state.angle_degree * push_angle_degrees), cannon_base_angle.z))
    print("[railgun net] late-join applied degree=%d; power=%g", cannon_late_join_state.angle_degree, cannon:get_field("_Power"))
    return retval
end)

print("loaded: full-health FINAL; base HP=160000; motion-speed=1.2; native multiplayer table; ground=60/fly=80/DPS=120; forced EXTRA disabled")

-- 10101 第二轮：ST405 单区历战王冻峰龙。仅由本任务宿主加载/摘钩。
-- JSON OptionTag=4 让原生 doAwake 选 QUEST_PHASE4；不逐帧写阶段，不重置迟加入计时。
-- TU5 静态依据：doAwake 14863A760；onDamageKeepHealth 14863E170；
-- checkStartWallStick 148640A30；trySetColumnNodeList 148640380；Generic.onStart 149C13F30。
-- hook 按类型/方法解析，不依赖静态地址；当前游戏 TDB 已只读核对。

quest.require_enemies { 1553456768 }

-- 与巨戟龙相同：冻峰普通/Hard动作倍率直接设为1.2，包卸载或任务退出恢复原值。
-- HealthRate_King_Hard=1.223：7400*11.05*1.223≈100005单人HP；多人表保持原生。
-- 不缩短核爆180秒主冷却和50秒准备计时，不改部位耐久。
local dahaad_legendary_param, original_dahaad_motion_speed_rate, original_dahaad_hard_motion_speed_rate
local original_dahaad_king_hard_health_rate
lib.on_enemy_package(EM0162, function(enemy_id)
    local enemy_package = sdk.get_managed_singleton("app.EnemyManager"):call("getPackage(app.EnemyDef.ID)", enemy_id)
    local legendary_param = enemy_package:get_field("_ParamPack"):get_field("_Legendary")
    dahaad_legendary_param = legendary_param
    original_dahaad_motion_speed_rate = legendary_param:get_field("MotionSpeedRate")
    original_dahaad_hard_motion_speed_rate = legendary_param:get_field("MotionSpeedRate_Hard")
    original_dahaad_king_hard_health_rate = legendary_param:get_field("HealthRate_King_Hard")
    legendary_param:set_field("MotionSpeedRate", 1.2)
    legendary_param:set_field("MotionSpeedRate_Hard", 1.2)
    legendary_param:set_field("HealthRate_King_Hard", 1.223)
    print("[dahaad-health] King Hard rate %g -> 1.223; solo HP about 100005", original_dahaad_king_hard_health_rate)
    print("[dahaad-motion-speed] normal %g -> 1.2; Hard %g -> 1.2",
        original_dahaad_motion_speed_rate, original_dahaad_hard_motion_speed_rate)
end, function()
    if dahaad_legendary_param == nil then return end
    dahaad_legendary_param:set_field("MotionSpeedRate", original_dahaad_motion_speed_rate)
    dahaad_legendary_param:set_field("MotionSpeedRate_Hard", original_dahaad_hard_motion_speed_rate)
    dahaad_legendary_param:set_field("HealthRate_King_Hard", original_dahaad_king_hard_health_rate)
    print("[dahaad-health] restored King Hard rate=%g", original_dahaad_king_hard_health_rate)
    print("[dahaad-motion-speed] restored normal=%g; Hard=%g",
        original_dahaad_motion_speed_rate, original_dahaad_hard_motion_speed_rate)
    dahaad_legendary_param = nil
end)

local dahaad_extend_type = sdk.find_type_definition("app.cEm0162_00Extend")

-- 冻峰初始化完成后将场景碰撞半径设为5；高度不动，不改攻击/受击判定。
-- 主核Part10耐久乘4，并提前解除首次核爆前的保底1；不触发核爆、不改冷却。
-- 只写当前实例，不改共享资源，不加逐帧hook；实例撤场随原生销毁。
local character_controller_type = sdk.find_type_definition("via.physics.CharacterController")
sdk.hook(dahaad_extend_type:get_method("doStartBegin()"), function(args)
    thread.get_hook_storage().dahaad_start_extend = sdk.to_managed_object(args[2])
end, function(retval)
    local hook_storage = thread.get_hook_storage()
    local dahaad_extend = hook_storage.dahaad_start_extend
    local character_controller = dahaad_extend:call("get_Character()"):call("get_CharaCtrl()")
    sdk.call_native_func(character_controller, character_controller_type, "set_Radius(System.Single)", 5.0)

    local main_core_damage_parts = dahaad_extend:call("get_Context()"):get_field("_Em")
        :get_field("Parts"):get_field("_DmgParts"):get_element(10)
    local main_core_vital_table = main_core_damage_parts:get_field("_NextMaxVitalTable")
    -- 实例独立的Single[]；已核对数据从0x20起，每项4字节，避免get_element装箱。
    for vital_index = 0, main_core_vital_table:get_size() - 1 do
        local vital_value_offset = 0x20 + vital_index * 4
        main_core_vital_table:write_float(vital_value_offset, main_core_vital_table:read_float(vital_value_offset) * 2)
    end
    -- 原生同步当前/默认/最大耐久，不改变耗尽次数或破坏次数。
    main_core_damage_parts:call("resetVitalAndUpdatCurrentVital()")
    dahaad_extend:call("set__IsIceNovaUsed(System.Boolean)", true)
    hook_storage.dahaad_start_extend = nil
    return retval
end)

-- 兜底奔跑到达距离放宽到20，避免贴边目标使大体型冻峰持续顶墙。
-- 只改LOOP_INSURANCE的cDashNoY；原生动作退出自动恢复，不改共享源参数。
sdk.hook(dahaad_extend_type:get_method("onEnterAction(ace.ACTION_ID)"), function(args)
    local action_id = sdk.to_valuetype(args[3], "ace.ACTION_ID")
    if action_id:call("get_Category()") ~= 0
        or action_id:call("get_Index()") ~= 11 then return end -- cDashNoY

    local dahaad_extend = sdk.to_managed_object(args[2])
    local enemy_context = dahaad_extend:call("get_Context()"):get_field("_Em")
    if enemy_context:get_field("BTable"):call("get_CurrentBTableID()") ~= 38 then return end

    local dash_action = dahaad_extend:call("get_Character()")
        :call("get_BaseActionController()")
        :call("getAction(ace.ACTION_ID)", action_id)
    dash_action:call("get_MoveFinishComp()")
        :call("overrideArraivalDistance(System.Single)", 20.0)
end, function(retval)
    return retval
end)

-- 原生伤害回调在 AreaMoveKeepHealthRate<=0 时仍可能恢复旧血量。
-- 必须绕过回调本体；只把门槛写成0会产生“单区不掉血”的反效果。
sdk.hook(dahaad_extend_type:get_method("onDamageKeepHealth"), function()
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    return retval
end)

-- 禁用原墙距/冰机关站位检查；避免ST405核爆前反复调整站位。
-- 两项均返回false；不恢复转区/攀墙hook，不改变核爆其余资格和计时。
for _, method_name in ipairs({ "cCheckDestWall", "cCheckDestShutterGimmick" }) do
    sdk.hook(sdk.find_type_definition("app.btable.Em0162_00BTableCommand." .. method_name)
        :get_method("onExecute"), function()
        return sdk.PreHookResult.SKIP_ORIGINAL
    end, function()
        return sdk.to_ptr(0)
    end)
end

-- 核爆只额外要求HP<40%；不限制位置，不要求跑回出生点。
-- 阶段、准备、目标、疲劳、破核和冷却全部由原生处理。
local ICENOVA_HEALTH_RATE = 0.4

sdk.hook(sdk.find_type_definition("app.Em0162_00_BTable_CommonAttack_Export")
    :get_method("table_839b3fd9_b07a_4f04_8a44_d3fd4d68abe2"), function(args)
    -- 已选动作继续执行，不在中途重新检查血量。
    if not sdk.to_managed_object(args[4]):call("get_IsExportTableJump()") then return end
    local health_manager = sdk.to_managed_object(args[3]):call("get_Context()")
        :get_field("_Chara"):call("get_HealthManager()")
    if health_manager:call("get_Health()") >= health_manager:call("get_MaxHealth()") * ICENOVA_HEALTH_RATE then
        thread.get_hook_storage().dahaad_nova_health_blocked = true
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end, function(retval)
    if thread.get_hook_storage().dahaad_nova_health_blocked then return sdk.to_ptr(0) end
    return retval
end)

-- 该接口只恢复既有GM607落冰母体；ST405无掩体，不走这条专门恢复链。
sdk.hook(sdk.find_type_definition("app.GimmickManager")
    :get_method("activateWallSheildForNoSheild(System.Int32)"), function()
    return sdk.PreHookResult.SKIP_ORIGINAL
end, function(retval)
    return retval
end)

-- 王版核爆FixedID=46：包加载时将最终半径95改为125；主伤害和强杀副球同步扩张。
-- 不改初始半径8、扩张时间0.4秒、寿命、伤害、冷气场或附加冰柱；不新增弹体hook。
local ICENOVA_RADIUS = 125.0
local ice_nova_radius_patch

lib.on_enemy_package(EM0162, function(enemy_id)
    local enemy_package = sdk.get_managed_singleton("app.EnemyManager")
        :call("getPackage(app.EnemyDef.ID)", enemy_id)
    local shell_list = enemy_package:get_field("_ParamPack")
        :get_field("_ShellCreatorInfoData"):get_field("_ShellList")
    local nova_index = shell_list:call("findShellIndexFromShellID(System.Int32)", 46)
    assert(nova_index >= 0, "Dahaad KING IceNova (FixedID=46) missing from ShellList")
    local nova_package = shell_list:call("getShellPackage(System.Int32)", nova_index)
    local nova_params = nova_package:call("get_MainParam()"):call("get_ShellMiniParams()")
    for param_index = 0, nova_params:call("get_Count()") - 1 do
        local nova_param = nova_params:call("get_Item(System.Int32)", param_index)
        if nova_param:get_type_definition():get_full_name() == "app.cShellMoveScale" then
            local original_radius = nova_param:get_field("_EndScale")
            ice_nova_radius_patch = { move_param = nova_param, original_radius = original_radius }
            nova_param:set_field("_EndScale", ICENOVA_RADIUS)
            print("[dahaad] nova radius %g -> %g", original_radius, ICENOVA_RADIUS)
            break
        end
    end
    assert(ice_nova_radius_patch ~= nil, "Dahaad KING IceNova cShellMoveScale missing")
end, function()
    if ice_nova_radius_patch == nil then return end
    ice_nova_radius_patch.move_param:set_field("_EndScale", ice_nova_radius_patch.original_radius)
    print("[dahaad] restored nova radius -> %g", ice_nova_radius_patch.original_radius)
    ice_nova_radius_patch = nil
end)

-- 冰场pattern1/2携带原ST402固定坐标，撤销坐标覆盖，随原生shootShell位置创建。
-- pattern3核爆附加冰场本身没有覆盖：不改其冰柱、范围、延迟、伤害或强杀副碰撞。
-- 只改HasValue这一字节，保留Nullable剩余31字节；动态字段偏移+尺寸检查防越界。
local original_create_pos_overrides = {}
local absolute_space_pattern_type = sdk.find_type_definition("app.cEm0162_00Extend.cAbsoluteSpaceGenericPatternData")
local overwrite_create_pos_field = absolute_space_pattern_type:get_field("OverwriteCreatePos")
local overwrite_create_pos_offset = overwrite_create_pos_field:get_offset_from_base()
assert(overwrite_create_pos_offset == 0x10 and overwrite_create_pos_field:get_type():get_valuetype_size() == 0x20,
    "Dahaad Nullable<vec3> layout mismatch; check current TDB before modifying")

lib.on_enemy_package(EM0162, function(enemy_id)
    local enemy_stage_resident = sdk.get_managed_singleton("app.EnemyManager")
        :call("getEnemyStageResident(app.EnemyDef.ID)", enemy_id)
    local absolute_zero_generic_data = enemy_stage_resident:get_field("_Unique"):get_field("_SpeciesInfo")
        :get_field("_AbsoluteZeroGenericData")
    for pattern_index = 0, absolute_zero_generic_data:call("get_Length") - 1 do
        local absolute_space_pattern_data = absolute_zero_generic_data:get_element(pattern_index)
        if absolute_space_pattern_data:get_field("OverwriteCreatePos"):get_field("_HasValue") then
            -- Nullable的payload首字节为_HasValue；live新建ValueType已核对字段/byte0一致。
            original_create_pos_overrides[#original_create_pos_overrides + 1] = {
                absolute_space_pattern_data = absolute_space_pattern_data, original_has_value = absolute_space_pattern_data:read_byte(overwrite_create_pos_offset),
            }
            absolute_space_pattern_data:write_byte(overwrite_create_pos_offset, 0)
        end
    end
    print("[dahaad] cleared %d ST402 fixed-position overrides; nova damage unchanged", #original_create_pos_overrides)
end, function()
    for _, original_create_pos_override in ipairs(original_create_pos_overrides) do
        original_create_pos_override.absolute_space_pattern_data:write_byte(overwrite_create_pos_offset, original_create_pos_override.original_has_value)
    end
    original_create_pos_overrides = {}
    print("[dahaad] restored fixed-position overrides")
end)

print("[dahaad] round2: KING/phase4/ST405 area2; nova HP<40%%/blast radius125; no ice-cover")
