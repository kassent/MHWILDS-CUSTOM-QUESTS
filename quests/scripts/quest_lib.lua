-- 自定义任务脚本公共库。
-- 任务脚本里 require("scripts.quest_lib") 装载: 宿主 QuestScript::Load 已把 package.path 指向
--   quests 目录(见 PersistentEventQuest main.cpp), 同目录模块/子目录模块均可 require。
-- 每个任务独占一个 ScriptState, require 缓存是 per-state 的: 每个任务各持一份副本,
--   卸载随 state 销毁, 无跨任务污染。
--
-- 提供(纯被动函数库, 所有 sdk.hook 安装都在各任务脚本里, 挂什么钩子任务文件一眼可见):
--   通用工具     parse_guid / get_mission_id_from_fixed / get_enemy_display_name
--                is_late_join / resolve_em_id / calc_route_guid_hash / get_npc_runtime_id
--   枚举         ROLE_ID / LEGENDARY_ID / ENEMY_LAYOUT_TYPE / CREATE_OPTION_BIT
--   预放置敌人   spawn_preplaced_enemies(em, stage, spawns) —— 表驱动注入
--                (hook 装在任务脚本, 模板见 10098.lua)
--   对话目录     load_mission_dialogues / unload_mission_dialogues —— 按任务 ID 装载
--   台词 NPC     spawn_speaker_npcs(npcs) —— spawn 任务台词需要的说话 NPC

local lib = {}

-- bootstrap 的 UpdateContext 在脚本本体执行前已填好 quest.quest_id, require 时即可用
local QUEST_TAG = string.format("[quest %d]", quest.quest_id)

-- ==================== 通用工具 ====================

function lib.parse_guid(s)
    return sdk.find_type_definition("System.Guid"):get_method("Parse(System.String)"):call(nil, s)
end

-- fixed id(如 26820) → 运行时 MissionIDList.ID, 解析失败返回 nil
function lib.get_mission_id_from_fixed(fixedId)
    local idWrapper = ValueType.new(sdk.find_type_definition("app.MissionIDList.ID"))
    if sdk.find_type_definition("app.MissionIDList"):get_method("getIDFromFixed(app.MissionIDList.ID_Fixed, app.MissionIDList.ID)"):call(nil, fixedId, idWrapper) then
        return idWrapper.value__
    end
    return nil
end

-- EmID -> 当前语言显示名(EnemyName 返回消息 GUID, via.gui.message.get 单参版跟当前语言)
function lib.get_enemy_display_name(emId)
    local guid = sdk.find_type_definition("app.EnemyDef"):get_method("EnemyName(app.EnemyDef.ID)"):call(nil, emId)
    if guid == nil then
        return nil
    end
    return sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)"):call(nil, guid)
end

-- 中间加入判定(原生 createMainTargetContext 同款门): 加入者不本地建, 等网络复制
function lib.is_late_join()
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
function lib.resolve_em_id(fixedId)
    local w = ValueType.new(sdk.find_type_definition("app.EnemyDef.ID"))
    if sdk.find_type_definition("app.EnemyDef"):get_method("getIDFromFixed(app.EnemyDef.ID_Fixed, app.EnemyDef.ID)"):call(nil, fixedId, w) then
        return w.value__
    end
    return nil
end

-- 路线 GUID → __AreaMoveRouteID(int)。与原生 FUN_148b89510 一致:
-- GUID 的 16 字节按小端组成 4 个 dword 做 XOR 折叠(运行时 createMainTargetContext/createBossRushEnemy
-- 都用这个哈希填 __AreaMoveRouteID, 路线系统按它检索)。
function lib.calc_route_guid_hash(s)
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

-- ==================== 枚举 ====================

---@enum app.EnemyDef.ROLE_ID System.Int32
lib.ROLE_ID = {
    NORMAL = 0,
    BOSS = 1,
    CHILED = 2,
    FRENZY = 3,
    COCOON = 4,
    ROLE_COLLAB_01 = 5,
    MAX = 6,
}

---@enum app.EnemyDef.LEGENDARY_ID System.Int32
lib.LEGENDARY_ID = {
    NONE = 0,
    NORMAL = 1,
    KING = 2,
    MAX = 3,
}

---@enum app.EnemyDef.ENEMY_LAYOUT_TYPE System.Int32
lib.ENEMY_LAYOUT_TYPE = {
    DEFAULT = 0,       -- 场景常驻/环境怪(官方植物走这条)
    MISSION_BOSS = 1,  -- 任务 boss 布局(SubBoss pog 通道)
    MISSION_ZAKO = 2,
    MISSION_ANIMAL = 3,
    MAX = 4,
}

---@enum app.EnemyDef.CREATE_OPTION_BIT System.Int32
lib.CREATE_OPTION_BIT = {
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

-- ==================== 预放置敌人 ====================
-- 复刻 a8561ce CustomSubBoss C++ 注入逻辑(a3194d3 修 Bitset 签名)为脚本版。
-- 原生机制: 联动召唤怪(如欧米茄的影蜘蛛)只能"预放置 + requestCollaboEmAppear 唤醒", 预放置来自
--   任务 sub-boss 布局(.pog); 布局资源缺席时原生链空转 -> 召唤空操作。替代方案: 用 pog
--   createContextEnemy 的同一终端 EnemyManager.create(STATIC, ..., ONLY_LOCAL) 注入 spawns 表。
-- 挂点由任务脚本选择并安装(模板见 10098.lua): EnemyManager.createMainTargetContext
--   (updateChangeLayout 的 STORY 分支, 每个客户端任何座位的任务布局流程必经; layouter 触发
--   依赖场景有非空敌人图, 干净客户端不成立), post 阶段等原生主怪创建落地后调
--   spawn_preplaced_enemies。每次调用全表放(一条 entry 一只, 无防重/无 stage 过滤);
--   不查场上已有, 与 pog 等外部放置互不感知 —— 多只同种就写多条 entry。
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

local ROLE_ID = lib.ROLE_ID
local LEGENDARY_ID = lib.LEGENDARY_ID
local ENEMY_LAYOUT_TYPE = lib.ENEMY_LAYOUT_TYPE
local CREATE_OPTION_BIT = lib.CREATE_OPTION_BIT

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
    arg:set_field("<AreaMoveRouteID>k__BackingField", entry._RouteID ~= nil and lib.calc_route_guid_hash(entry._RouteID) or 0)
    arg:set_field("<EventTargetID>k__BackingField", entry._EventTargetID or -1)
    arg:set_field("<IsMainTarget>k__BackingField", false)

    local difficultyGuid = lib.parse_guid(entry._DifficultyRankId)
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
            arg:set_field("<ModelRandomSizeTblId>k__BackingField", lib.parse_guid(entry._RandomSizeTblId))
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
        QUEST_TAG, lib.get_enemy_display_name(emId), emId, entry._EmID, stage, areaNo, contextId, info ~= nil and "OK" or "null"))
end

-- late-join 门 + 全表 spawn; 由任务脚本的 createMainTargetContext post hook 调用。
-- IsLateJoin 门与原生同款: 中间加入者不本地建, 等网络复制(复制包自带全套创建参数, 实测)。
function lib.spawn_preplaced_enemies(em, stage, spawns)
    log.info(string.format("%s createMainTargetContext fired: stage=%d", QUEST_TAG, stage))
    if lib.is_late_join() then
        log.info(string.format("%s spawn skipped: late join, wait for net replication", QUEST_TAG))
        return
    end
    for slot, entry in ipairs(spawns) do
        local emId = lib.resolve_em_id(entry._EmID)
        if emId == nil then
            log.error(string.format("%s spawn: getIDFromFixed failed for %d", QUEST_TAG, entry._EmID))
        else
            spawn_quest_enemy(em, stage, entry, emId, slot)
        end
    end
end

-- ==================== 对话目录 ====================
-- 对话数据按任务 ID 加载: registerCatalog 把 cCatalogData._TargetMissionIDFixedList 索引进
--   DialogueResourceManager._DialogueCatalogDataList_MissionID, 任务开始时只加载目标列表含
--   本任务的目录。自定义任务不在原任务对话目录的目标列表里 → 原任务台词不加载 → 沉默。
--   这里手动把原任务的对话目录加载进来, 任务结束时卸载。

function lib.load_mission_dialogues(missionFixed)
    local missionId = lib.get_mission_id_from_fixed(missionFixed)
    if missionId == nil then
        log.error(string.format("%s getIDFromFixed failed for mission fixed=%d", QUEST_TAG, missionFixed))
        return
    end
    sdk.get_managed_singleton("app.DialogueResourceManager"):call("requestLoadDialogueList_MissionID(app.MissionIDList.ID)", missionId)
    log.info(string.format("%s loaded dialogue catalog for mission fixed=%d id=%d", QUEST_TAG, missionFixed, missionId))
end

function lib.unload_mission_dialogues(missionFixed)
    local missionId = lib.get_mission_id_from_fixed(missionFixed)
    if missionId == nil then
        return
    end
    sdk.get_managed_singleton("app.DialogueResourceManager"):call("requestUnLoadDialogueList_MissionID(app.MissionIDList.ID)", missionId)
    log.info(string.format("%s unloaded dialogue catalog for mission fixed=%d id=%d", QUEST_TAG, missionFixed, missionId))
end

-- ==================== 台词 NPC ====================
-- 任务台词的说话 NPC 由原故事任务布置, 自定义任务里没有:
--   begin NPC 不存在 → isPlayableCheck_GuiModule 静默丢弃; 第二个 actor 不存在 → talk player 建不出来。
-- 参数用 26820 实测捕获: GroupAIType=INDEPENDENCE(15), LayoutType=NONE(798760128)。
-- npcs 表: { fixed = NpcDef.ID_Fixed, pos = {x,y,z} }; findNpcInfo 去重, 重复调用不会多刷。
-- hook 触发器由任务脚本自己装: 用任务必刷 NPC(如阿尔玛 fixed 86)的 createContextHolder_Npc
--   作信号(该时刻场景必然已加载, 比 cQuestPlaying 更早更稳), 模板见 10098.lua。

-- NpcDef fixed id → 运行时 id, 解析失败返回 nil
function lib.get_npc_runtime_id(fixed)
    local w = ValueType.new(sdk.find_type_definition("app.NpcDef.ID"))
    if sdk.find_type_definition("app.NpcDef"):get_method("getIDFromFixed(app.NpcDef.ID_Fixed, app.NpcDef.ID)"):call(nil, fixed, w) then
        return w.value__
    end
    return nil
end

function lib.spawn_speaker_npcs(npcs)
    local getIDFromFixed = sdk.find_type_definition("app.NpcDef"):get_method("getIDFromFixed(app.NpcDef.ID_Fixed, app.NpcDef.ID)")
    local npcManager = sdk.get_managed_singleton("app.NpcManager")
    for _, speaker in ipairs(npcs) do
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
            log.info(string.format("%s spawned speaker npc fixed=%d runtime=%d", QUEST_TAG, speaker.fixed, npcIdWrapper.value__))
        end
    end
end

return lib
