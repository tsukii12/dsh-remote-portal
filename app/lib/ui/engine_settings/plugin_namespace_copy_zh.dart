// Chinese titles and enum labels for popular plugins, checked against the published version
// noted on each namespace. Copy only: no defaults, aliases or units.
import 'schema_fields.dart';

// l10n:keep-begin Chinese-only data; namespace_copy excludes this table in English.
const pluginNamespaceTitlesZh = <String, String>{
  'dsh-context': '上下文管理',
  'imagegen': '图像生成工作台',
  'auto-review': 'AI 自动审查',
  'furongjun1999-dsh-memory': '灵枢记忆',
  'agent-teams': '代理团队',
  'mobile-access': '移动端访问',
  'anime-find': '番剧搜索',
  'dsh-media': '图像与视频',
  'univer': '表格与文档',
  'speech-to-text-sensevoice': 'SenseVoice 本地识别',
};

const pluginNamespaceCopyZh = <String, Map<String, FieldCopy>>{
  // dsh-context 0.78.2; bundle row: dsh-context.
  'dsh-context': {
    'maxRequestSteps': FieldCopy(label: '请求步骤保留上限'),
    'maxKeptTurns': FieldCopy(label: '对话轮次保留上限'),
    'maxEvents': FieldCopy(label: '事件保留上限'),
    'maxNodes': FieldCopy(label: '节点保留上限'),
    'maxArchiveNodes': FieldCopy(label: '归档节点保留上限'),
    'maxFileOps': FieldCopy(label: '文件操作保留上限'),
    'maxCommands': FieldCopy(label: '命令保留上限'),
    'maxCommandChars': FieldCopy(label: '命令字符数上限'),
    'defaultPlacement': FieldCopy(
      label: '上下文面板入口',
      choices: {'all': '全部', 'tab': '标签页', 'sidebar': '侧边栏', 'hide': '隐藏'},
    ),
    'defaultGranularity': FieldCopy(
      label: '趋势图 · 粒度',
      choices: {'step': '步骤', 'turn': '轮次'},
    ),
    'defaultTrendMode': FieldCopy(
      label: '趋势图 · 展示方式',
      choices: {'total': '全量', 'delta': '增量'},
    ),
    'defaultDeltaBase': FieldCopy(
      label: '上下文浏览器 · 对比基线',
      choices: {'step': '步骤', 'turn': '轮次'},
    ),
    'defaultToolSort': FieldCopy(
      label: '工具定义 · 排序',
      choices: {'size': '按大小', 'count': '按次数', 'name': '按名称'},
    ),
    'defaultFileSort': FieldCopy(
      label: '文件活动 · 排序',
      choices: {
        'count': '按次数',
        'lines': '按行数',
        'latest': '按最新',
        'path': '按路径',
        'name': '按文件名',
      },
    ),
    'insightsEntry': FieldCopy(
      label: '上下文洞察',
      choices: {'show': '显示', 'hide': '隐藏'},
    ),
    'defaultDurationCurve': FieldCopy(
      label: '趋势图 · 耗时曲线',
      choices: {'show': '显示', 'hide': '隐藏'},
    ),
    'overviewAutoSteps': FieldCopy(
      label: '趋势图 · 自动总览',
      choices: {'100': '100 步', '200': '200 步', '300': '300 步', 'off': '不启用'},
    ),
    'defaultOverviewRange': FieldCopy(
      label: '上下文洞察 · 默认时间范围',
      choices: {'today': '今天', '7d': '近 7 天', '30d': '近 30 天', 'all': '全部'},
    ),
    'fleetTab': FieldCopy(
      label: '编队标签页',
      choices: {'show': '显示', 'hide': '隐藏'},
    ),
    'promptPrefix': FieldCopy(label: '系统提示词前缀', hint: '拼接在系统提示词之前'),
    'promptSuffix': FieldCopy(label: '系统提示词后缀', hint: '拼接在系统提示词之后'),
  },
  // @dickpy/dsh-imagegen 1.10.0; bundle row: imagegen.
  'imagegen': {
    'enabled': FieldCopy(label: '启用插件', hint: '关闭后生图面板不可用'),
    'announceToAgent': FieldCopy(label: '向 Agent 播报本插件', hint: '将能力写入系统提示词'),
    'allowAgentImageGeneration': FieldCopy(
      label: '允许 Agent 调用生图',
      hint: '侧边栏工作台不受此开关影响',
    ),
    'channels': FieldCopy(label: '提供方渠道', hint: '图像服务与模型配置'),
    'defaultChannelId': FieldCopy(label: '默认渠道 ID'),
    'defaultModel': FieldCopy(label: '默认模型'),
    'promptApiUrl': FieldCopy(label: '对话 API 地址'),
    'promptApiKey': FieldCopy(label: '对话 API 密钥（可选）'),
    'promptModel': FieldCopy(label: '对话模型'),
    'localStoragePath': FieldCopy(label: '本地图片存储目录'),
    'storageEnabled': FieldCopy(label: '启用对象存储同步', hint: '本地图片异步同步到对象存储'),
    'storageEndpoint': FieldCopy(label: '接口地址（含存储桶）'),
  },
  // dsh-auto-review 0.15.0; bundle row: auto-review.
  'auto-review': {
    'enableByDefault': FieldCopy(label: '默认启用自动审查'),
    'toolsPolicy.default': FieldCopy(
      label: '默认工具审查策略',
      hint: '适用于未单独配置的工具',
      choices: {'ai': '由 AI 审查', 'human': '交由人工审查', 'never': '拒绝审批请求'},
    ),
    'reviewerModel': FieldCopy(label: '审查模型'),
    'reviewerModelProvider': FieldCopy(label: '审查模型服务商'),
    'reviewerTimeoutMs': FieldCopy(label: '审查超时'),
    'reviewerGuidance': FieldCopy(label: '审查指导文本'),
    'maxReviewsPerTurn': FieldCopy(label: '每轮审查次数上限'),
    'maxFailuresPerTurn': FieldCopy(label: '每轮失败次数上限'),
    'contextBudget.turns': FieldCopy(label: '审查上下文轮数'),
    'contextBudget.maxChars': FieldCopy(label: '审查上下文字符数上限'),
    'language': FieldCopy(label: '审查语言', choices: {'en': '英语', 'zh': '中文'}),
  },
  // @furongjun1999/dsh-memory 0.9.17; bundle row: furongjun1999-dsh-memory.
  'furongjun1999-dsh-memory': {
    'serverName': FieldCopy(label: '记忆服务名称'),
    'python': FieldCopy(label: 'Python 程序路径'),
    'dbPath': FieldCopy(label: '记忆数据库路径'),
    'identity': FieldCopy(label: '身份名称'),
    'toolAliases': FieldCopy(label: '兼容工具别名', hint: '保留旧工具名别名'),
    'memory.userMessage': FieldCopy(label: '将用户消息存为记忆'),
    'memory.assistantMessage': FieldCopy(label: '将助手消息存为记忆'),
    'memory.toolResult': FieldCopy(label: '将工具结果存为记忆'),
    'memory.autoRecall': FieldCopy(label: '自动召回记忆'),
    'memory.autoRecallLimit': FieldCopy(label: '自动召回数量上限'),
    'memory.contextWindow.enabled': FieldCopy(
      label: '短期会话窗口',
      hint: '控制窗口记录与上下文注入',
    ),
    'memory.contextWindow.turns': FieldCopy(
      label: '窗口保留记录数',
      hint: '按记录条数计，不按对话轮数',
    ),
    'toolCallTimeoutMs': FieldCopy(label: '工具调用超时'),
  },
  // @nanmicoder/dsh-agent-teams 0.1.27; bundle row: agent-teams.
  'agent-teams': {
    'stateDir': FieldCopy(label: '团队状态目录', hint: '保存团队与消息状态'),
    'memberProvider': FieldCopy(label: '成员启动方式'),
    'memberModel': FieldCopy(label: '成员模型'),
    'memberLlmProvider': FieldCopy(label: '成员模型服务商'),
    'executionPrompt': FieldCopy(label: '成员执行提示词'),
    'maxMembers': FieldCopy(label: '成员数量上限'),
    'memberMaxDepth': FieldCopy(label: '成员子代理层数上限', hint: '0 表示不允许继续创建子代理'),
    'profiles': FieldCopy(label: '团队配置方案'),
    'slashCommand': FieldCopy(label: '斜杠命令入口'),
  },
  // dsh-mobile 0.7.0; bundle row: mobile-access.
  'mobile-access': {
    'listenHost': FieldCopy(label: '监听地址'),
    'listenPort': FieldCopy(label: '监听端口'),
    'publicOrigin': FieldCopy(label: '公开访问地址'),
    'upstreamOrigin': FieldCopy(label: '上游服务地址'),
    'setupFile': FieldCopy(label: '访问设置文件'),
    'stateFile': FieldCopy(label: '设备状态文件'),
    'customCssFile': FieldCopy(label: '自定义样式文件'),
    'customScriptFile': FieldCopy(label: '自定义脚本文件'),
    'maxDevices': FieldCopy(label: '设备数量上限'),
    'maxSessions': FieldCopy(label: '会话数量上限'),
    'maxConnections': FieldCopy(label: '连接数量上限'),
    'upstreamTimeoutMs': FieldCopy(label: '上游请求超时'),
  },
  // @cocofhu/anime-find 0.1.12; bundle row: anime-find.
  'anime-find': {
    'mikanHost': FieldCopy(label: 'Mikan 站点'),
    'anibtHost': FieldCopy(label: 'AniBT 站点'),
    'gardenHost': FieldCopy(label: 'AnimeGarden API'),
    'timeoutMs': FieldCopy(label: '上游请求超时'),
    'userAgent': FieldCopy(label: '请求 UA'),
    'maxResults': FieldCopy(label: '搜索结果上限'),
    'sources': FieldCopy(label: '启用的搜索源'),
    'streamEnabled': FieldCopy(label: '启用流媒体在线播放'),
    'streamRules': FieldCopy(label: '流媒体规则', hint: 'CSS、XPath 或取址脚本'),
  },
  // @ccch1mneyyy/dsh-media 0.2.1; bundle row: dsh-media.
  'dsh-media': {
    'services': FieldCopy(label: '媒体服务'),
    'defaults.serviceId': FieldCopy(label: '默认服务 ID', hint: '留空使用首个已配置服务'),
    'defaults.modelId': FieldCopy(label: '默认模型 ID', hint: '留空使用所选服务首项'),
    'limits.maxVideoBytes': FieldCopy(label: '视频原件字节上限'),
    'limits.maxImages': FieldCopy(label: '单次图片张数上限'),
    'limits.maxImageBytes': FieldCopy(label: '单张原件字节上限'),
    'limits.maxResponseBytes': FieldCopy(label: '服务响应字节上限'),
    'limits.maxTotalImageBytes': FieldCopy(label: '单次原件总字节上限'),
  },
  // dsh-univer-office 0.3.9; bundle row: univer.
  'univer': {
    'autoOpenLivePreview': FieldCopy(label: '自动打开实时预览'),
    'conversationReviewCards': FieldCopy(label: '会话审阅卡片'),
    'gatewayPort': FieldCopy(label: '协作网关端口'),
    'autoStartGateway': FieldCopy(label: '自动启动协作网关'),
    'gatewayStartupTimeoutMs': FieldCopy(label: '网关启动超时'),
    'gatewayRequestTimeoutMs': FieldCopy(label: '网关请求超时'),
    'screenshotMaxPages': FieldCopy(label: '截图页数上限'),
    'screenshotMaxPixels': FieldCopy(label: '截图像素数上限'),
    'browserExecutablePath': FieldCopy(label: '浏览器程序路径'),
    'resourceCacheRoot': FieldCopy(label: '资源缓存目录'),
  },
  // @deepseek-ai/dsh-experimental-speech-to-text-sensevoice 未知（所属bundle为0.2.1-rc.4）; bundle row: speech-to-text-sensevoice.
  'speech-to-text-sensevoice': {
    'providerId': FieldCopy(label: '识别服务 ID'),
    'dataRoot': FieldCopy(label: '识别服务数据目录'),
    'modelDirectory': FieldCopy(label: '模型目录'),
    'vadModelPath': FieldCopy(label: '语音活动检测模型路径'),
    'precision': FieldCopy(
      label: '模型精度',
      choices: {'int8': 'INT8 量化', 'fp32': 'FP32 浮点'},
    ),
    'threads': FieldCopy(label: '识别线程数'),
    'maxAudioBytes': FieldCopy(label: '录音大小上限（字节）'),
    'inferenceTimeoutMs': FieldCopy(label: '识别超时'),
  },
};
// l10n:keep-end
