-- 任务 10099 (终末四重奏) 运行时定制脚本。
-- 生命周期由插件宿主管理: cQuestSceneLoading 时装载本脚本, cQuestResult 时销毁 state 并自动摘钩;
--   各功能块自带"还原"函数, 统一在文末 quest.on_unload 里收尾。
--
-- 功能块:
--   1. 对话目录     手动加载原 Omega 任务的对话目录(自定义任务不在其目标列表, 不加台词沉默)
--   2. 动作速度     白炽龙/黑蚀龙/欧米茄动作提速(package 加载时改 Legendary 参数)
--   3. 火海寿命     芥末炸弹火海出生即无限寿命
--   4. 暴走锁定     欧米茄暴走不可被脚伤击破解除
--   5. 预放置敌人   QUEST_ENEMY_SPAWNS 表驱动注入(影蜘蛛联动召唤等)
--   6. 台词 NPC     补 spawn 欧米茄台词的两个说话 NPC

local QUEST_TAG = "[quest 10099]"

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

-- ==================== 2. 动作速度 ====================
-- hook EnemyManager 的 package 加载/卸载。加载完成后沿
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
    log.info(string.format("%s restored motion speed for EmID=%d(%s): MotionSpeedRate %.2f -> %.2f, MotionSpeedRate_Hard %.2f -> %.2f",
        QUEST_TAG, id, get_enemy_display_name(id), cur, b.rate, curHard, b.rateHard))
end

-- args[1]=vmctx args[2]=this args[3]=EmID(32位枚举: to_int64 后 & 0xFFFFFFFF 截出来)
sdk.hook(sdk.find_type_definition("app.EnemyManager"):get_method("onLoadPackage(app.EnemyDef.ID)"), function(args)
    local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
    log.info(string.format("%s onLoadPackage EmID=%d(%s)", QUEST_TAG, id, get_enemy_display_name(id)))

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
        log.info(string.format("%s patched motion speed for EmID=%d(%s): MotionSpeedRate %.2f -> %.2f, MotionSpeedRate_Hard %.2f -> %.2f",
            QUEST_TAG, id, get_enemy_display_name(id), rate, legendary.MotionSpeedRate, rateHard, legendary.MotionSpeedRate_Hard))
    end
end)

sdk.hook(sdk.find_type_definition("app.EnemyManager"):get_method("onUnloadRequestPackage(app.EnemyDef.ID)"), function(args)
    local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
    log.info(string.format("%s onUnloadRequestPackage EmID=%d(%s)", QUEST_TAG, id, get_enemy_display_name(id)))
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
        log.info(string.format("%s slip area lifetime %.1f -> infinite", QUEST_TAG, life))
    end
end)

local function restore_slip_lifetime()
    for _, b in ipairs(slip_lifetime_patched) do
        b.obj:set_field("_LifeSec", b.orig)
    end
    if #slip_lifetime_patched > 0 then
        log.info(string.format("%s restored slip area lifetime for %d CommonParam(s)", QUEST_TAG, #slip_lifetime_patched))
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
    log.info(string.format("%s rampage scar down rate %d/%d -> 0/0 (leg scar break no longer exits rampage)", QUEST_TAG, rate, rateHl))
end)

local function restore_rampage_rate()
    for _, b in ipairs(rampage_rate_patched) do
        b.obj:set_field("_ScarRampageDownRate", b.orig)
        b.obj:set_field("_ScarRampageDownRate_HL", b.origHl)
    end
    if #rampage_rate_patched > 0 then
        log.info(string.format("%s restored rampage scar down rate for %d ParamUnique(s)", QUEST_TAG, #rampage_rate_patched))
    end
    rampage_rate_patched = {}
end

-- ==================== 5. 预放置敌人 ====================
-- 复刻 a8561ce CustomSubBoss C++ 注入逻辑(a3194d3 修 Bitset 签名)为脚本版。
-- 原生机制: 联动召唤怪(如欧米茄的影蜘蛛)只能"预放置 + requestCollaboEmAppear 唤醒", 预放置来自
--   任务 sub-boss 布局(.pog); 布局资源缺席时原生链空转 -> 召唤空操作。这里 hook
--   ContextLayouter.requestCreateContextEnemy(布局链收敛点, 每个客户端各自调用, 与 bossrush 的
--   host-only create 不同), post 阶段用 pog createContextEnemy 的同一终端
--   EnemyManager.create(STATIC, ..., ONLY_LOCAL) 注入 QUEST_ENEMY_SPAWNS 里的每条敌人。
-- hook 每次触发都全表放(一条 entry 一只, 无防重/无 stage 过滤); 不查场上已有,
--   与 pog 等外部放置互不感知 —— 多只同种就写多条 entry。
--
-- entry 字段对照 quest MainTargetDataList / pog ContextLayoutEnemy 节点:
--   emFixedId      必填, EnemyDef.ID_Fixed(json 里的 _EmID, 如 -1363370496=影蜘蛛 EM0070_00_0)
--   pos            必填, {x,y,z} 世界坐标
--   difficultyGuid 必填, 难度 GUID(照抄同星数活动任务/原 pog 节点)
--   roleId         默认 NORMAL; ROLE_COLLAB_01(requestCollaboEmAppear 联动唤醒只认它)
--   legendaryId    默认 NONE
--   optionTag      默认 0(照抄源节点)
--   storyTargetId  默认 0
--   fixedSize      默认 100(useRandomSize=false 时生效)
--   useRandomSize  默认 false; true 走随机体型: randomSizeTblGuid 非零填 _RandomSizeTblId 的 GUID,
--                  留空退回 difficultyGuid 当随机尺寸源(照抄原生 _IsUseRandomSize 分支)
--   areaNo         默认 -1 = 按 pos 自动算(getAreaNoNearPoint)
--   deepSleep      默认 false; true → CREATE_OPTION_BIT.DEFAULT_DEEP_SLEEP(预放置深眠, 唤醒链前置条件)
--   routeGuid      默认无路线(0); 填 MainTarget/pog 节点里的 _RouteID._Value(如 st403 白炽龙 fc4f203d-...)
--   groupId        默认 0; layoutKeepId 默认 -1

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
    { -- 影蜘蛛 A(欧米茄 SpAtk 召唤用, 参数照抄 st402_SubBoss_Ms730025 节点 / 自制 pog 实测值)
        emFixedId = -1363370496, -- EM0070_00_0
        roleId = ROLE_ID.ROLE_COLLAB_01,
        optionTag = 1,
        storyTargetId = 10,
        pos = { -2.297, 0.426, 73.488 },                         -- 竞技场中心(pog 实测位置)
        difficultyGuid = "f326f227-c0ff-47bb-92e7-aa187d61ad3c", -- Ms630007 蜘蛛节点难度
        deepSleep = true,
    },
    { -- 影蜘蛛 B(同上, 站位不同)
        emFixedId = -1363370496, -- EM0070_00_0
        roleId = ROLE_ID.ROLE_COLLAB_01,
        optionTag = 1,
        storyTargetId = 11,
        pos = { 24.183, -0.323, 92.306 },                        -- 实测坐标
        difficultyGuid = "f326f227-c0ff-47bb-92e7-aa187d61ad3c",
        deepSleep = true,
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

    local pos = Vector3f.new(entry.pos[1], entry.pos[2], entry.pos[3])
    transform:set_field("<Position>k__BackingField", pos)
    transform:set_field("<Rotation>k__BackingField", Quaternion.identity())
    arg:set_field("<Transform>k__BackingField", transform)

    arg:set_field("<EmID>k__BackingField", emId)
    arg:set_field("<RoleID>k__BackingField", entry.roleId or ROLE_ID.NORMAL)
    arg:set_field("<LegendaryID>k__BackingField", entry.legendaryId or LEGENDARY_ID.NONE)
    arg:set_field("<LayoutType>k__BackingField", 1) -- ENEMY_LAYOUT_TYPE.MISSION_BOSS
    arg:set_field("<StageNo>k__BackingField", stage)
    arg:set_field("<OptionTag>k__BackingField", entry.optionTag or 0)
    arg:set_field("<StoryTargetID>k__BackingField", entry.storyTargetId or 0)
    arg:set_field("<LayoutKeepID>k__BackingField", entry.layoutKeepId or -1)
    arg:set_field("<GroupID>k__BackingField", entry.groupId or 0)
    arg:set_field("<AreaMoveRouteID>k__BackingField", entry.routeGuid ~= nil and calc_route_guid_hash(entry.routeGuid) or 0)
    arg:set_field("<EventTargetID>k__BackingField", -1)
    arg:set_field("<IsMainTarget>k__BackingField", false)

    local difficultyGuid = parse_guid(entry.difficultyGuid)
    arg:set_field("<DifficultyRankId>k__BackingField", difficultyGuid)

    local bits = arg:get_field("<CreateOptionBit>k__BackingField")
    if entry.deepSleep then
        bits:call("on(System.Int32)", CREATE_OPTION_BIT.DEFAULT_DEEP_SLEEP_FROM_STORY)
    end

    -- 尺寸(照抄原生 _IsUseRandomSize 分支): false → bit7 禁随机体型 + ModelFixedSize
    --   (Nullable 打包 (size<<16)|1, 与 createMainTargetContext 算法一致);
    --   true → randomSizeTblGuid 非零填随机尺寸表 GUID, 否则退回难度 GUID 当随机尺寸源
    if entry.useRandomSize then
        if entry.randomSizeTblGuid ~= nil and entry.randomSizeTblGuid ~= "00000000-0000-0000-0000-000000000000" then
            arg:set_field("<ModelRandomSizeTblId>k__BackingField", parse_guid(entry.randomSizeTblGuid))
        else
            arg:set_field("<ModelRandomSizeDifficultyRankId>k__BackingField", difficultyGuid)
        end
    else
        bits:call("on(System.Int32)", CREATE_OPTION_BIT.DISABLE_RANDOM_SCALE)
        arg:set_field("<ModelFixedSize>k__BackingField", (entry.fixedSize or 100) * 0x10000 + 1)
    end

    local areaNo = entry.areaNo or -1
    if areaNo < 0 then
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
        QUEST_TAG, get_enemy_display_name(emId), emId, entry.emFixedId, stage, areaNo, contextId, info ~= nil and "OK" or "null"))
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
            local emId = resolve_em_id(entry.emFixedId)
            if emId == nil then
                log.error(string.format("%s spawn: getIDFromFixed failed for %d", QUEST_TAG, entry.emFixedId))
            else
                spawn_quest_enemy(em, stage, entry, emId, slot)
            end
        end
    end)

-- ==================== 6. 台词 NPC ====================
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
-- 兜底: package 卸载若发生在脚本摘钩之后, 这里把还没还原的一次性还原
quest.on_load(function()
    load_omega_mission_dialogues()
    log.info(string.format("%s quest script loaded", QUEST_TAG))
end)

-- 任务 flow 变化只打印阶段名, 观察任务流程用
quest.on_flow_changed(function(flow)
    log.info(string.format("%s flow: %s", QUEST_TAG, flow))
end)

quest.on_unload(function()
    for id in pairs(motion_speed_patched) do
        restore_motion_speed_patch(id)
    end
    restore_slip_lifetime()
    restore_rampage_rate()
    unload_omega_mission_dialogues()
    log.info(string.format("%s unloading quest script, hooks will be removed", QUEST_TAG))
end)
