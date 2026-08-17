-- 任务 10098 (零式欧米茄复刻) 运行时定制脚本。
-- 生命周期由插件宿主管理: cQuestSceneLoading 时装载本脚本, cQuestResult 时销毁 state 并自动摘钩;
--   各功能块自带"还原"函数, 统一在文末 quest.on_unload 里收尾。
--
-- 功能块:
--   1. 对话目录     手动加载原 Omega 任务的对话目录(自定义任务不在其目标列表, 不加台词沉默)
--   2. 预放置敌人   QUEST_ENEMY_SPAWNS 表驱动注入(影蜘蛛联动召唤)
--   3. 台词 NPC     补 spawn 欧米茄台词的两个说话 NPC
--   4. 常驻声明     require_enemies 声明魔界花幼苗/仙人刺(环境生物不在 Boss+Zako 全量范围)
-- (高难增强版 —— 动作速度/火海寿命/暴走锁定/双蜘蛛 —— 见 10099.lua)

local QUEST_TAG = "[quest 10098]"

-- ==================== 通用工具 ====================

local function parse_guid(s)
    return sdk.find_type_definition("System.Guid"):get_method("Parse(System.String)"):call(nil, s)
end

-- fixed id(如 26820) → 运行时 MissionIDList.ID, 解析失败返回 nil
local function get_mission_id_from_fixed(fixedId)
    local idWrapper = ValueType.new(sdk.find_type_definition("app.MissionIDList.ID"))
    if sdk.find_type_definition("app.MissionIDList"):get_method("getIDFromFixed(app.MissionIDList.ID_Fixed, app.MissionIDList.ID)"):call(nil, fixedId, idWrapper) then
        return idWrapper.value__
    end
    return nil
end

-- EmID -> 当前语言显示名(EnemyName 返回消息 GUID, via.gui.message.get 单参版跟当前语言)
local function get_enemy_display_name(emId)
    local guid = sdk.find_type_definition("app.EnemyDef"):get_method("EnemyName(app.EnemyDef.ID)"):call(nil, emId)
    if guid == nil then
        return nil
    end
    return sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)"):call(nil, guid)
end

-- ==================== 1. 对话目录 ====================
-- 对话数据按任务 ID 加载: registerCatalog 把 cCatalogData._TargetMissionIDFixedList 索引进
--   DialogueResourceManager._DialogueCatalogDataList_MissionID, 任务开始时只加载目标列表含
--   本任务的目录。自定义任务不在 Omega 对话目录(Ms730020)的目标列表里 → Omega 台词不加载
--   → 沉默。这里手动把原任务的对话目录加载进来, 任务结束时卸载。

local OMEGA_MISSION_FIXED = 26820 -- Ms730020 零式欧米茄 (Dia_stCh7301_Ms730020_*)

local function load_omega_mission_dialogues()
    local missionId = get_mission_id_from_fixed(OMEGA_MISSION_FIXED)
    if missionId == nil then
        log.error(string.format("%s getIDFromFixed failed for mission fixed=%d", QUEST_TAG, OMEGA_MISSION_FIXED))
        return
    end
    sdk.get_managed_singleton("app.DialogueResourceManager"):call("requestLoadDialogueList_MissionID(app.MissionIDList.ID)", missionId)
    log.info(string.format("%s loaded dialogue catalog for mission fixed=%d id=%d", QUEST_TAG, OMEGA_MISSION_FIXED, missionId))
end

local function unload_omega_mission_dialogues()
    local missionId = get_mission_id_from_fixed(OMEGA_MISSION_FIXED)
    if missionId == nil then
        return
    end
    sdk.get_managed_singleton("app.DialogueResourceManager"):call("requestUnLoadDialogueList_MissionID(app.MissionIDList.ID)", missionId)
    log.info(string.format("%s unloaded dialogue catalog for mission fixed=%d id=%d", QUEST_TAG, OMEGA_MISSION_FIXED, missionId))
end

-- ==================== 2. 预放置敌人 ====================
-- 复刻 a8561ce CustomSubBoss C++ 注入逻辑(a3194d3 修 Bitset 签名)为脚本版。
-- 原生机制: 联动召唤怪(如欧米茄的影蜘蛛)只能"预放置 + requestCollaboEmAppear 唤醒", 预放置来自
--   任务 sub-boss 布局(.pog); 布局资源缺席时原生链空转 -> 召唤空操作。这里 hook
--   ContextLayouter.requestCreateContextEnemy(布局链收敛点, 每个客户端各自调用, 与 bossrush 的
--   host-only create 不同), post 阶段用 pog createContextEnemy 的同一终端
--   EnemyManager.create(STATIC, ..., ONLY_LOCAL) 注入 QUEST_ENEMY_SPAWNS 里的每条敌人。
-- hook 每次触发都全表放(一条 entry 一只, 无防重/无 stage 过滤); 不查场上已有,
--   与 pog 等外部放置互不感知 —— 多只同种就写多条 entry。
--
-- entry 字段与 pog ContextLayoutEnemy 节点同名字段一一对照(见 st402_Em5010/5011_AnimalContextLayout.pog.12.json),
-- 方便和官方文件逐字段对照修改:
--   _EmID               必填, EnemyDef.ID_Fixed(pog 节点 _EmID / graph 级 cSharedData._EmId, 如 -1363370496=影蜘蛛)
--   _Position           必填, {x,y,z} 世界坐标(pog Position)
--   _Rotation           可选, {x,y,z,w}, 缺省 identity
--   _DifficultyRankId   必填, 难度 GUID(pog _DifficultyRankId.Value; 环境怪照官方填全零)
--   _RoleID             默认 NORMAL; ROLE_COLLAB_01(requestCollaboEmAppear 联动唤醒只认它)
--   _LegendaryID        默认 NONE
--   _OptionTag          默认 0(照抄源节点); 植物 1/2=入睡变体(wakeUpEm5010Em5011 用 STANDBY 唤醒)
--   _StoryTargetID      默认 0; _EventTargetID 默认 -1; _GroupID 默认 0; _LayoutKeepID 默认 -1
--   _SetAreaNo          默认 255(自动, getAreaNoNearPoint; pog 同款哨兵)
--   _IsUseRandomSize    默认 false → bit7 禁随机体型 + _FixedSize(Nullable (size<<16)|1);
--                       true → _RandomSizeTblId 非全零填随机尺寸表 GUID, 否则退回 _DifficultyRankId
--                       当随机尺寸源(照抄原生 _IsUseRandomSize 分支)
--   _RouteID            默认无路线(0); 填 MainTarget/pog 节点里的 _RouteID._Value(如 st403 白炽龙 fc4f203d-...)
--   _AdvancedSettings   { _IsDefaultDeepSleep = true } → CREATE_OPTION_BIT.DEFAULT_DEEP_SLEEP_FROM_STORY
--                       (bit4 预放置深眠, FSM 通道, 蜘蛛唤醒链前置条件; 植物入睡走 _OptionTag 变体, 不用这个)
--   _LayoutType         默认 ENEMY_LAYOUT_TYPE.MISSION_BOSS; 环境怪填 DEFAULT(官方植物实测 0)

---@enum app.EnemyDef.ROLE_ID System.Int32
local ROLE_ID = {
    NORMAL = 0,
    BOSS = 1,
    CHILED = 2,
    FRENZY = 3,
    COCOON = 4,
    ROLE_COLLAB_01 = 5,
    MAX = 6,
}

---@enum app.EnemyDef.LEGENDARY_ID System.Int32
local LEGENDARY_ID = {
    NONE = 0,
    NORMAL = 1,
    KING = 2,
    MAX = 3,
}

---@enum app.EnemyDef.ENEMY_LAYOUT_TYPE System.Int32
local ENEMY_LAYOUT_TYPE = {
    DEFAULT = 0,       -- 场景常驻/环境怪(官方植物走这条)
    MISSION_BOSS = 1,  -- 任务 boss 布局(SubBoss pog 通道)
    MISSION_ZAKO = 2,
    MISSION_ANIMAL = 3,
    MAX = 4,
}

---@enum app.EnemyDef.CREATE_OPTION_BIT System.Int32
local CREATE_OPTION_BIT = {
    DEFAULT_NPC_JACK = 0,
    DEFAULT_DIE = 1,
    DEFAULT_REPOP = 2,
    CHANGE_STATE_ENTRY = 3,
    DEFAULT_DEEP_SLEEP_FROM_STORY = 4,
    DEFAULT_VISIBLE_ENABLE_DEEP_SLEEP = 5,
    DEFALUT_HAGITORI_ZERO = 6,
    DISABLE_RANDOM_SCALE = 7,
    DEFAULT_GRAPPLE_SUMMONED = 8,
    DEFAULT_DEEP_SLEEP = 9,
    BASE_CAMP_ANIMAL = 10,
    PREVIEW_ANIMAL = 11,
    FORCE_CREATION_SYNC = 12,
    DISABLE_CAPTURE_REWARD = 13,
    DEFAULT_DIE_NOT_EFFECT = 14,
    MAX = 15,
}

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

-- 中间加入者判定(与原生 createMainTargetContext 开头的门同款):
-- NetworkManager -> get_UserInfoManager() -> getSelfUserInfo(QUEST, false) -> IsLateJoin
-- 原生语义: 中间加入不本地创建任务怪, 等网络复制; 注入遵循同一规则, 避免孤儿副本。
local function is_late_join()
    local net = sdk.get_managed_singleton("app.NetworkManager")
    if net == nil then
        return false
    end
    local uim = net:call("get_UserInfoManager()")
    if uim == nil then
        return false
    end
    local info = uim:call("getSelfUserInfo(app.net_session_manager.SESSION_TYPE, System.Boolean)", 2, false)
    return info ~= nil and info:get_field("<IsLateJoin>k__BackingField") == true
end

-- json 里的 _EmID(fixedId) → 运行时 EnemyDef.ID, 失败返回 nil
local function resolve_em_id(fixedId)
    local w = ValueType.new(sdk.find_type_definition("app.EnemyDef.ID"))
    if sdk.find_type_definition("app.EnemyDef"):get_method("getIDFromFixed(app.EnemyDef.ID_Fixed, app.EnemyDef.ID)"):call(nil, fixedId, w) then
        return w.value__
    end
    return nil
end

-- 路线 GUID → __AreaMoveRouteID(int)。与原生 FUN_148b89510 一致:
-- GUID 的 16 字节按小端组成 4 个 dword 做 XOR 折叠(运行时 createMainTargetContext/createBossRushEnemy
-- 都用这个哈希填 __AreaMoveRouteID, 路线系统按它检索)。
local function calc_route_guid_hash(s)
    local a, b, c, d, e = s:match("^(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x%x%x%x%x%x%x%x%x)$")
    local tail = d .. e
    local bytes = {}
    for i = 1, #tail, 2 do bytes[#bytes + 1] = tonumber(tail:sub(i, i + 1), 16) end
    local d0 = tonumber(a, 16)
    local d1 = tonumber(b, 16) | (tonumber(c, 16) << 16)
    local d2 = bytes[1] | (bytes[2] << 8) | (bytes[3] << 16) | (bytes[4] << 24)
    local d3 = bytes[5] | (bytes[6] << 8) | (bytes[7] << 16) | (bytes[8] << 24)
    local v = (d0 ~ d1 ~ d2 ~ d3) & 0xFFFFFFFF
    if v >= 0x80000000 then v = v - 0x100000000 end -- 转成 Int32
    return v
end

local function spawn_quest_enemy(em, stage, entry, emId, slot)
    --- @type app.cContextCreateArg_Enemy
    local arg = sdk.find_type_definition("app.cContextCreateArg_Enemy"):create_instance()
    --- @type app.cContextTransform
    local transform = sdk.find_type_definition("app.cContextTransform"):create_instance()
    if arg == nil or transform == nil then
        log.error(string.format("%s spawn emId=%d: create_instance failed", QUEST_TAG, emId))
        return
    end

    local pos = Vector3f.new(entry._Position[1], entry._Position[2], entry._Position[3])
    transform:set_field("<Position>k__BackingField", pos)
    local rot = entry._Rotation
    transform:set_field("<Rotation>k__BackingField",
        rot ~= nil and Quaternion.new(rot[1], rot[2], rot[3], rot[4]) or Quaternion.identity())
    arg:set_field("<Transform>k__BackingField", transform)

    arg:set_field("<EmID>k__BackingField", emId)
    arg:set_field("<RoleID>k__BackingField", entry._RoleID or ROLE_ID.NORMAL)
    arg:set_field("<LegendaryID>k__BackingField", entry._LegendaryID or LEGENDARY_ID.NONE)
    arg:set_field("<LayoutType>k__BackingField", entry._LayoutType or ENEMY_LAYOUT_TYPE.MISSION_BOSS)
    arg:set_field("<StageNo>k__BackingField", stage)
    arg:set_field("<OptionTag>k__BackingField", entry._OptionTag or 0)
    arg:set_field("<StoryTargetID>k__BackingField", entry._StoryTargetID or 0)
    arg:set_field("<LayoutKeepID>k__BackingField", entry._LayoutKeepID or -1)
    arg:set_field("<GroupID>k__BackingField", entry._GroupID or 0)
    arg:set_field("<AreaMoveRouteID>k__BackingField", entry._RouteID ~= nil and calc_route_guid_hash(entry._RouteID) or 0)
    arg:set_field("<EventTargetID>k__BackingField", entry._EventTargetID or -1)
    arg:set_field("<IsMainTarget>k__BackingField", false)

    local difficultyGuid = parse_guid(entry._DifficultyRankId)
    arg:set_field("<DifficultyRankId>k__BackingField", difficultyGuid)

    local bits = arg:get_field("<CreateOptionBit>k__BackingField")
    if entry._AdvancedSettings ~= nil and entry._AdvancedSettings._IsDefaultDeepSleep then
        bits:call("on(System.Int32)", CREATE_OPTION_BIT.DEFAULT_DEEP_SLEEP_FROM_STORY)
    end

    -- 尺寸(照抄原生 _IsUseRandomSize 分支): false → bit7 禁随机体型 + _FixedSize
    --   (Nullable 打包 (size<<16)|1, 与 createMainTargetContext 算法一致);
    --   true → _RandomSizeTblId 非全零填随机尺寸表 GUID, 否则退回难度 GUID 当随机尺寸源
    if entry._IsUseRandomSize then
        if entry._RandomSizeTblId ~= nil and entry._RandomSizeTblId ~= "00000000-0000-0000-0000-000000000000" then
            arg:set_field("<ModelRandomSizeTblId>k__BackingField", parse_guid(entry._RandomSizeTblId))
        else
            arg:set_field("<ModelRandomSizeDifficultyRankId>k__BackingField", difficultyGuid)
        end
    else
        bits:call("on(System.Int32)", CREATE_OPTION_BIT.DISABLE_RANDOM_SCALE)
        arg:set_field("<ModelFixedSize>k__BackingField", (entry._FixedSize or 100) * 0x10000 + 1)
    end

    local areaNo = entry._SetAreaNo or 255
    if areaNo < 0 or areaNo == 255 then
        areaNo = em:call("getAreaNoNearPoint(via.vec3, app.FieldDef.STAGE)", pos, stage)
    end
    arg:set_field("<AreaNo>k__BackingField", areaNo)

    -- 高 graph/node 下标避开真实布局怪(graph=200 照抄 C++, node=900+entry 下标)
    local contextId = sdk.find_type_definition("app.EnemyUtil")
        :get_method("makeStaticContextId(app.FieldDef.STAGE, System.Int32, System.Int32, System.Boolean, System.Boolean)")
        :call(nil, stage, 200, 900 + slot, false, true)

    local info = em:call(
        "create(app.EnemyDef.CONTEXT_SUB_CATEGORY, System.Int32, app.cContextCreateArg_Enemy, app.EnemyDef.SYNC_TYPE, via.GameObject)",
        0, contextId, arg, 2, nil) -- CONTEXT_SUB_CATEGORY.STATIC / SYNC_TYPE.ONLY_LOCAL
    if info ~= nil then
        -- 官方无父 context 账本(createMainTargetContext 同款: create 第 5 参 GO=null 后登记)
        local handle = info:call("get_Context()"):get_field("_Handle")
        em:get_field("_NoParentContextHandleList"):call("Add(app.CONTEXT_HANDLE)", handle)
    end
    log.info(string.format("%s spawn %s(emId=%d, fixed=%d): stage=%d area=%d contextId=%d -> %s",
        QUEST_TAG, get_enemy_display_name(emId), emId, entry._EmID, stage, areaNo, contextId, info ~= nil and "OK" or "null"))
end

-- 触发器: EnemyManager.createMainTargetContext —— updateChangeLayout 的 STORY 分支,
--   每个客户端(任何座位)的任务布局流程必经(四组联机实测; layouter 触发依赖场景有非空敌人图,
--   干净客户端不成立)。post 阶段等原生主怪创建落地后注入。
-- IsLateJoin 门与原生同款: 中间加入者不本地建, 等网络复制(复制包自带全套创建参数, 实测)。
sdk.hook(sdk.find_type_definition("app.EnemyManager"):get_method("createMainTargetContext(app.FieldDef.STAGE, System.Boolean)"),
    function(args)
        local storage = thread.get_hook_storage()
        storage.em = sdk.to_managed_object(args[2])
        storage.stage = sdk.to_int64(args[3]) & 0xFFFFFFFF
    end,
    function(retval)
        local storage = thread.get_hook_storage()
        local em, stage = storage.em, storage.stage
        if em == nil then
            return
        end
        log.info(string.format("%s createMainTargetContext fired: stage=%d", QUEST_TAG, stage))
        if is_late_join() then
            log.info(string.format("%s spawn skipped: late join, wait for net replication", QUEST_TAG))
            return
        end
        for slot, entry in ipairs(QUEST_ENEMY_SPAWNS) do
            local emId = resolve_em_id(entry._EmID)
            if emId == nil then
                log.error(string.format("%s spawn: getIDFromFixed failed for %d", QUEST_TAG, entry._EmID))
            else
                spawn_quest_enemy(em, stage, entry, emId, slot)
            end
        end
    end)

-- ==================== 3. 台词 NPC ====================
-- 欧米茄台词的两个说话 NPC 由原故事任务布置, 自定义任务里没有:
--   begin NPC 不存在 → isPlayableCheck_GuiModule 静默丢弃; 第二个 actor 不存在 → talk player 建不出来。
--   两个都得 spawn。参数用 26820 实测捕获: GroupAIType=INDEPENDENCE(15), LayoutType=NONE(798760128)。
--   位置用本任务竞技场中心附近(st403), 原 st402 坐标不适用。

local OMEGA_SPEAKER_NPCS = {
    { fixed = 25679, pos = { -2.297, 0.426, 73.488 } }, -- NPC510_50_030 游星欧米茄 (begin NPC)
    { fixed = 16659, pos = { -4.0, 0.426, 71.0 } },     -- NPC510_50_026 欧米茄 (第二 actor)
}
local speaker_spawned = false

local function spawn_omega_speaker_npcs()
    local getIDFromFixed = sdk.find_type_definition("app.NpcDef"):get_method("getIDFromFixed(app.NpcDef.ID_Fixed, app.NpcDef.ID)")
    local npcManager = sdk.get_managed_singleton("app.NpcManager")
    for _, speaker in ipairs(OMEGA_SPEAKER_NPCS) do
        local npcIdWrapper = ValueType.new(sdk.find_type_definition("app.NpcDef.ID"))
        local ok = getIDFromFixed:call(nil, speaker.fixed, npcIdWrapper)
        if not ok then
            log.error(string.format("%s getIDFromFixed failed for npc fixed=%d", QUEST_TAG, speaker.fixed))
        elseif npcManager:call("findNpcInfo_NpcId(System.Int32)", npcIdWrapper.value__) == nil then
            npcManager:call(
                "createNpc(System.Int32, via.vec3, via.Quaternion, app.NpcDef.GROUP_AI_TYPE, app.NpcDef.NPC_CONTEXT_LAYOUT_TYPE_Fixed)",
                npcIdWrapper.value__,
                Vector3f.new(speaker.pos[1], speaker.pos[2], speaker.pos[3]),
                Quaternion.identity(),
                15, 798760128)
            log.info(string.format("%s spawned omega speaker npc fixed=%d runtime=%d", QUEST_TAG, speaker.fixed, npcIdWrapper.value__))
        end
    end
end

-- 触发器: 阿尔玛(fixed 86)是任务必刷 NPC, 她的 createContextHolder_Npc 时刻场景必然已加载,
--   比 cQuestPlaying 更早更稳。我们自己的 spawn 会重入本 hook, 但 NpcID 不匹配触发条件, 不会递归。
local ALMA_NPC_FIXED = 86
local almaRuntimeId = nil
do
    local w = ValueType.new(sdk.find_type_definition("app.NpcDef.ID"))
    if sdk.find_type_definition("app.NpcDef"):get_method("getIDFromFixed(app.NpcDef.ID_Fixed, app.NpcDef.ID)"):call(nil, ALMA_NPC_FIXED, w) then
        almaRuntimeId = w.value__
    end
end

sdk.hook(sdk.find_type_definition("app.ContextManager"):get_method("createContextHolder_Npc(app.cContextCreateArg_Npc)"), function(args)
    if speaker_spawned or almaRuntimeId == nil then
        return
    end
    local arg = sdk.to_managed_object(args[3])
    if arg:call("get_NpcID()") == almaRuntimeId then
        speaker_spawned = true
        spawn_omega_speaker_npcs()
    end
end)

-- ==================== 生命周期 ====================
quest.on_load(function()
    -- 声明本任务场景需要的 EnemyDef.ID_Fixed: 宿主 hook setStageResidentDataDicts 时
    --   合并进当前场景 _EmIDList(不限场景), 场景即可刷新它们(环境生物不在 Boss+Zako 全量范围)
    quest.require_enemies{
        31768, -- EM5011_00_0 魔界花幼苗
        9549,  -- EM5010_00_0 仙人刺
    }
    load_omega_mission_dialogues()
    log.info(string.format("%s quest script loaded", QUEST_TAG))
end)

-- 任务 flow 变化只打印阶段名, 观察任务流程用
quest.on_flow_changed(function(flow)
    log.info(string.format("%s flow: %s", QUEST_TAG, flow))
end)

quest.on_unload(function()
    unload_omega_mission_dialogues()
    log.info(string.format("%s unloading quest script, hooks will be removed", QUEST_TAG))
end)
