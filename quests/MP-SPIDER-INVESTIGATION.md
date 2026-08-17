# 蜘蛛注入联机问题调查实录（2026-08-16 ~ 08-17）

一次性记录本轮调查的完整证据链、被推翻的假设、最终结论与架构。
逆向细节的函数/地址级分析见 `d:\dev\mhwilds\.claude\skills\mhwilds-custom-quest\SKILL.md` 与记忆节点，本文只记调查过程与结论。

---

## 一、问题定义

自制任务 10098（零式欧米茄复刻，st403）用 Lua 脚本注入影蜘蛛（deep-sleep + ROLE_COLLAB_01，供 Omega SpAtk 召唤）。联机症状：

1. 别人进我任务看不到蜘蛛
2. 我进别人任务蜘蛛开局就出现、站着不动没有 AI
3. Omega 大招召唤时蜘蛛不响应

## 二、最终架构（全部实测验证）

```
触发器: hook EnemyManager.createMainTargetContext(STAGE, Boolean) post
门禁:   IsLateJoin(原生同款) — 中间加入者不建, 等网络复制
注入:   create(STATIC, makeStaticContextId(stage,200,900+slot), arg, ONLY_LOCAL, nil)
        arg 带 bit4 深眠 + bit7 禁随机体型 + storyTargetId 对齐 _SubBossInfoArray
账本:   不登记任何一边的特色账本(_CreatedContextHandleList / _NoParentContextHandleList)
        — 唯一清理保障是 create() 内部必进的 _AllEnemyList
语义:   STATIC 实体 + 每客户端各自本地建 + NetInfo 按 id 配对成网(host 权威驱动状态)
```

## 三、证据链（按时间序，含被推翻的假设）

### 3.1 双探针 dump（autorun 脚本，log 在 re2_framework_log.txt）

`[create-dump]` = hook EnemyManager.create（本地创建路径）；`[ctx-dump]` = hook createContextHolder_Enemy（全路径，含网络复制）。

**发现 1：中间加入者的蜘蛛不走 create()。**
加入官方任务，蜘蛛/欧米茄只有 `[ctx-dump]` 行无 `[create-dump]` 行——任务怪经网络复制直接物化 context，参数全套随包传输（pos 与官方 pog 节点逐位一致：-307.29, 149.87, 822.37）。**复制不需要 pog 文件不需要 mod。**

**发现 2：中间加入者的布局槽全零。**
活体读 `_LayoutInfoArray[stage]` 的 Boss/Zako/AnimalLayoutIDForMission 全 00000000——中间加入走 TAKE_OVER，"任务布局 GUID→槽位"的写入被跳过 → ContextLayouter 的 MISSION_BOSS 过滤器对全零槽匹配不到任何图 → 原生 pog 链在加入者身上创建不了任务怪。

**发现 3：官方从头进场 = 每客户端本地 create(STATIC, ONLY_LOCAL)。**
2P 客人 `[create-dump]` 直接打出官方蜘蛛（graph=10 node=1，pog 真实节点下标，bits=[4,7]，flag=1）——和我们的注入机制逐字段相同。配对标志是 NetInfo 的成员索引（hostIdx=0/selfIdx=1），编造的 graph=200/node=901 **不影响配对**（同法实测我们的注入怪也有正确 NetInfo）。

**发现 4：`IsNetSyncCreate` 不是判别标志**——官方正常工作的怪在从头进场客户端上也是 false（它只标记"由复制创建"）。

### 3.2 触发器可靠性四组数据

| Run | 座位 | createMainTargetContext | requestCreateContextEnemy | 本地蜘蛛 |
|---|---|---|---|---|
| 03:47 | 朋友=host | - | ✗ | ✗ |
| 03:47 | 我=guest | - | ✓ | ✓ |
| 04:10 | 我=host | ✓ | ✓ | ✓ |
| 04:10 | 朋友=guest | ✓ | ✗ | ✗ |

规律不是座位是**客户端**。根源两级：

1. **requestCreateContextEnemy 的调用机制**（反编译闭环）：它没有直接代码调用者，是 `ContextLayouter.awake()` 里**当 PointGraph 有非空敌人型图时**才订阅到 `EnemyManager.OnRequestChangeLayout` 事件的委托——订阅成立与否依赖场景图内容，天然不稳定。
2. **我的客户端为什么总成立**：`D:\MO2\mhwilds\mods\Over\natives\...\st403\SubBoss\` 还残留着 `st403_SubBoss_Ms990025.pog.12` + **`st403_SubBoss_poglist.poglst.0`**——poglst 让场景无条件枚举加载该 pog（不需要任务 GUID）→ 我的 holder 永远有非空敌人图 → awake 订阅成功。朋友没有这份 natives → 永不订阅。**"我的机器能触发"是实验室事故（Over 残留文件的副产品）。**
3. **createMainTargetContext 是普适触发器**：updateChangeLayout 的 STORY 分支（任务装载必经，host/guest 实测都触发）。

完整调用链：

```
布局变更请求 → EnemyManager.updateChangeLayout:
    changeLayout(写布局槽) →
    ├─ STORY 分支 → createMainTargetContext(stage, flag)   ← 最终触发器(hook 此处)
    ├─ EX 分支    → EnemyExSetter.requestCreateContextEnemy(大世界探索)
    └─ 末尾 OnRequestChangeLayout 事件 → 已订阅 layouter 的 requestCreateContextEnemy
                                          (订阅依赖 awake 时图非空, 不稳)
```

### 3.3 修正过程中的错误与教训

| 错误 | 纠正 |
|---|---|
| 深眠位用了 `DEFAULT_DEEP_SLEEP`(bit9) | 蜘蛛可见冻结、召唤不醒。原生 pog 链是 bit4（`DEFAULT_DEEP_SLEEP_FROM_STORY`，createContextEnemy 反编译 `\|= 0x10` 实证）。bit9 语义至今未逆向 |
| layouter 触发器（语义优雅） | 丢了 host 覆盖；a8561ce 当年选 createMainTargetContext 是对的 |
| 无条件注入（无门禁） | 中间加入者/客人端产生孤儿副本（可见冻结、等不到唤醒） |
| 把 NoParent 账本登记安在 STATIC 实体上 | 语义错位（那是 DYNAMIC 主目标路径的后续动作）；STATIC 的对位是 layouter 账本，但换触发器后无对象。结论：都不登记，`_AllEnemyList` 足矣 |
| hook createContextHolder_Enemy 在 post 拼超长单行 | 集会所崩游戏。热路径 hook 必须 pre + 短行 |
| snapshot 轮询探针 | 用户要求纯 hook；轮询撤除 |
| "官方行长 88" | 拍脑袋值；实测官方分布后修正：拉丁 ≤64 字符、CJK ≤30 全角字（按渲染长度，占位符标签渲染后只占几字） |

## 四、机制知识沉淀（本轮新钉死）

1. **STATIC vs DYNAMIC**（`CONTEXT_SUB_CATEGORY`）：
   - STATIC = 场景的一部分——id 是布局位置的确定性哈希（makeStaticContextId 位域：bit0=flag / bit1=isNpc / bits2-11=node / bits12-19=graph / bits20-24=stage），每客户端各自本地建、NetInfo 按 id 配对
   - DYNAMIC = 事件的一部分——id 是语义字段哈希（makeDynamicContextId 位域：bits21-24=CREATE_TYPE(0=EX_SETTER/1=STORY_ACTION_ENEMY/2=QUEST_MAIN_TARGET) / bits13-20=emId / bits7-12=groupID / bits1-6=序号），requestCreate 异步 + ONLY_MASTER（host 造+广播，客人被动收——所以客人的 create hook 永远看不到主目标）
   - 主目标走 DYNAMIC+动态id+requestCreate；pog 布局怪走 STATIC+静态id+同步create；我们的注入对位的是后者
2. **同步类型**：主目标/pog 怪/注入怪全是 ONLY_LOCAL——SYNC_TYPE 控制的是"创建事件是否实时广播"不是"实体是否进网络世界"；网络可见性由 NetInfo 配对/世界快照承担
3. **中间加入**：布局槽不写（TAKE_OVER）、布局链空转、一切任务怪靠世界快照复制（自带全套 cContextCreateArg_Enemy）；`getAreaNoNearPoint` 等空间查询依赖场景已加载，任务外调用恒 255
4. **force-complete 型修复不成立**：host 的 ONLY_LOCAL 静态怪**不会**自动同步给从头进场的无 mod 客人（04:10 实测：朋友的 ctx-dump 蜘蛛行=0）
5. **PogList（.poglst）**：场景无条件枚举加载目录内 pog 的清单文件——残留的 poglst+pog 是我机器上 layouter 触发稳定的真因

## 五、遗留问题与后续方向

1. **无 mod 客人**：当前架构要求所有客户端装当前版本 mod。要支持 host 单装，需转 DYNAMIC+ONLY_MASTER 广播语义（或试 `FORCE_CREATION_SYNC` bit12，枚举里躺着没人用过）——未实验
2. **EX 分支覆盖**：createMainTargetContext 只盖 STORY 分支。竞技场任务全是 STORY（双座位实测）；大地图任务（st101-105）可能走 EX——届时把 layouter hook 加回当兜底（共享 once 标志）即可，方案就绪
3. **bit9（DEFAULT_DEEP_SLEEP）语义**：未逆向，只知症状（可见冻结、不可唤醒）
4. **bit0 保留位**：静态 id 的 bit0=LayoutType!=DEFAULT 标记；动态 id 的 bit0 未确认用途
5. **测试矩阵未跑完**：新触发器版（cmtc + IsLateJoin 门）改完后还没和朋友联机验证——从头进双方注入+配对+召唤同步、中间加入者 skipped+复制出怪
6. **Over natives 清理**：`D:\MO2\mhwilds\mods\Over\natives\...\st403\SubBoss\`（pog.12 + poglst.0）是触发器稳定性的隐性依赖，新架构下不再需要，但删掉会改变本机行为（layouter 不再触发——对 cmtc 触发器无影响），留作环境变量记录
