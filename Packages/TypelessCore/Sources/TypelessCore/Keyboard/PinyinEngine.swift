import Foundation

/// Pinyin input engine for Chinese character lookup
///
/// Converts pinyin syllable sequences to Chinese character candidates.
/// Uses a built-in dictionary for common characters and phrases.
public actor PinyinEngine {
    /// Current pinyin input buffer
    private var inputBuffer: String = ""

    /// Cached candidates for current input
    private var cachedCandidates: [PinyinCandidate] = []

    public init() {}

    /// Add a character to the pinyin input buffer
    public func appendCharacter(_ char: String) -> [PinyinCandidate] {
        inputBuffer += char.lowercased()
        cachedCandidates = lookupCandidates(for: inputBuffer)
        return cachedCandidates
    }

    /// Remove the last character from the pinyin input buffer
    public func deleteLastCharacter() -> [PinyinCandidate] {
        guard !inputBuffer.isEmpty else { return [] }
        inputBuffer = String(inputBuffer.dropLast())
        if inputBuffer.isEmpty {
            cachedCandidates = []
        } else {
            cachedCandidates = lookupCandidates(for: inputBuffer)
        }
        return cachedCandidates
    }

    /// Select a candidate, clearing the buffer and returning the selected text
    public func selectCandidate(at index: Int) -> String? {
        guard index >= 0, index < cachedCandidates.count else { return nil }
        let selected = cachedCandidates[index]
        inputBuffer = ""
        cachedCandidates = []
        return selected.text
    }

    /// Clear the pinyin buffer
    public func clear() {
        inputBuffer = ""
        cachedCandidates = []
    }

    /// Get the current pinyin input buffer
    public var currentInput: String {
        inputBuffer
    }

    /// Get current candidates
    public var candidates: [PinyinCandidate] {
        cachedCandidates
    }

    // MARK: - Dictionary Lookup

    /// Look up Chinese character candidates for pinyin input
    private func lookupCandidates(for pinyin: String) -> [PinyinCandidate] {
        guard !pinyin.isEmpty else { return [] }

        var results: [PinyinCandidate] = []

        // Look up in the built-in dictionary
        if let exact = PinyinDictionary.lookup[pinyin] {
            results += exact.enumerated().map { index, char in
                PinyinCandidate(text: char, pinyin: pinyin, frequency: 1000 - index)
            }
        }

        // Also check partial matches (prefix matching)
        for (key, chars) in PinyinDictionary.lookup where key.hasPrefix(pinyin) && key != pinyin {
            results += chars.prefix(3).enumerated().map { index, char in
                PinyinCandidate(text: char, pinyin: key, frequency: 500 - index)
            }
        }

        // Sort by frequency (most common first)
        return results
            .sorted { $0.frequency > $1.frequency }
            .prefix(30)
            .map { $0 }
    }
}

/// A candidate Chinese character/phrase for pinyin input
public struct PinyinCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let pinyin: String
    public let frequency: Int

    public init(text: String, pinyin: String, frequency: Int = 0) {
        self.id = "\(text)-\(pinyin)"
        self.text = text
        self.pinyin = pinyin
        self.frequency = frequency
    }
}

/// Built-in pinyin to Chinese character dictionary
/// This is a minimal starter dictionary; a production app would use a larger database
public enum PinyinDictionary {
    // swiftlint:disable line_length
    public static let lookup: [String: [String]] = [
        // Common single-character pinyin
        "a": ["啊", "阿", "呵"],
        "ai": ["爱", "哎", "唉", "矮", "癌"],
        "an": ["安", "按", "暗", "岸"],
        "ang": ["昂"],
        "ao": ["奥", "熬", "傲"],
        "ba": ["吧", "八", "把", "爸", "拔"],
        "bai": ["白", "百", "拜", "败"],
        "ban": ["半", "办", "班", "般", "版"],
        "bang": ["帮", "棒", "绑", "榜"],
        "bao": ["包", "报", "抱", "宝", "保"],
        "bei": ["被", "北", "背", "备", "杯"],
        "ben": ["本", "笨", "奔"],
        "bi": ["比", "笔", "必", "闭", "避"],
        "bian": ["变", "边", "便", "遍", "编"],
        "biao": ["表", "标", "彪"],
        "bie": ["别", "憋"],
        "bin": ["宾", "滨"],
        "bing": ["并", "病", "冰", "兵"],
        "bo": ["不", "波", "播", "博", "伯"],
        "bu": ["不", "步", "部", "布", "补"],
        "ca": ["擦"],
        "cai": ["才", "菜", "猜", "财", "材"],
        "can": ["参", "惨", "餐", "残"],
        "cang": ["藏", "仓", "苍"],
        "cao": ["草", "操", "曹"],
        "ce": ["测", "策", "册", "侧"],
        "cha": ["查", "差", "茶", "察", "插"],
        "chai": ["拆", "柴"],
        "chan": ["产", "缠", "馋", "禅"],
        "chang": ["长", "常", "场", "唱", "厂"],
        "chao": ["超", "朝", "抄", "炒", "吵"],
        "che": ["车", "彻", "扯"],
        "chen": ["陈", "沉", "晨", "称", "趁"],
        "cheng": ["成", "城", "程", "称", "承"],
        "chi": ["吃", "持", "池", "迟", "尺"],
        "chong": ["重", "冲", "充", "虫"],
        "chou": ["抽", "丑", "臭", "愁"],
        "chu": ["出", "处", "初", "除", "楚"],
        "chuan": ["穿", "传", "船", "川"],
        "chuang": ["床", "窗", "创", "闯"],
        "chui": ["吹", "垂", "锤"],
        "chun": ["春", "纯", "醇"],
        "ci": ["次", "此", "词", "辞", "磁"],
        "cong": ["从", "聪", "丛"],
        "cu": ["粗", "醋", "促"],
        "cun": ["村", "存", "寸"],
        "cuo": ["错", "措"],
        "da": ["大", "打", "达", "答"],
        "dai": ["带", "代", "待", "袋", "戴"],
        "dan": ["但", "单", "担", "蛋", "淡"],
        "dang": ["当", "党", "挡", "档"],
        "dao": ["到", "道", "倒", "刀", "导"],
        "de": ["的", "得", "德"],
        "dei": ["得"],
        "deng": ["等", "灯", "登", "邓"],
        "di": ["地", "第", "低", "底", "敌"],
        "dian": ["点", "电", "店", "典", "殿"],
        "diao": ["掉", "调", "钓", "吊"],
        "die": ["跌", "叠", "爹", "蝶"],
        "ding": ["定", "丁", "顶", "盯", "钉"],
        "dong": ["东", "动", "冬", "懂", "洞"],
        "dou": ["都", "斗", "豆", "逗"],
        "du": ["度", "读", "独", "毒", "堵"],
        "duan": ["段", "短", "断", "端"],
        "dui": ["对", "队", "堆"],
        "dun": ["顿", "吨", "蹲", "盾"],
        "duo": ["多", "朵", "躲", "夺"],
        "e": ["额", "恶", "饿", "鹅"],
        "en": ["恩", "嗯"],
        "er": ["二", "而", "耳", "儿"],
        "fa": ["发", "法", "罚", "伐"],
        "fan": ["反", "饭", "番", "烦", "犯"],
        "fang": ["方", "放", "房", "防", "访"],
        "fei": ["非", "费", "飞", "废", "肥"],
        "fen": ["分", "份", "粉", "纷", "坟"],
        "feng": ["风", "丰", "封", "疯", "锋"],
        "fo": ["佛"],
        "fu": ["服", "福", "父", "付", "副", "夫", "富", "复"],
        "ga": ["嘎"],
        "gai": ["该", "改", "盖", "概"],
        "gan": ["干", "感", "敢", "赶", "甘"],
        "gang": ["刚", "钢", "港", "岗"],
        "gao": ["高", "告", "搞", "稿"],
        "ge": ["个", "各", "歌", "哥", "格"],
        "gei": ["给"],
        "gen": ["跟", "根", "更"],
        "geng": ["更", "耕", "梗"],
        "gong": ["工", "公", "功", "共", "供"],
        "gou": ["够", "狗", "沟", "勾", "构"],
        "gu": ["古", "故", "顾", "谷", "骨"],
        "gua": ["挂", "瓜", "刮", "寡"],
        "guai": ["怪", "乖", "拐"],
        "guan": ["关", "管", "观", "官", "馆"],
        "guang": ["光", "广", "逛"],
        "gui": ["贵", "归", "鬼", "柜", "规"],
        "gun": ["滚", "棍"],
        "guo": ["过", "国", "果", "锅", "裹"],
        "ha": ["哈", "蛤"],
        "hai": ["还", "海", "害", "孩", "嗨"],
        "han": ["汉", "含", "喊", "寒", "韩"],
        "hang": ["行", "航", "杭"],
        "hao": ["好", "号", "毫", "豪", "耗"],
        "he": ["和", "合", "何", "河", "喝"],
        "hei": ["黑", "嘿"],
        "hen": ["很", "恨", "狠"],
        "heng": ["横", "恒", "衡"],
        "hong": ["红", "洪", "宏", "虹"],
        "hou": ["后", "候", "厚", "猴", "吼"],
        "hu": ["胡", "湖", "虎", "护", "户"],
        "hua": ["话", "花", "画", "化", "华"],
        "huai": ["坏", "怀", "淮"],
        "huan": ["还", "换", "环", "欢", "缓"],
        "huang": ["黄", "皇", "慌", "荒"],
        "hui": ["会", "回", "灰", "汇", "辉"],
        "hun": ["混", "婚", "魂", "昏"],
        "huo": ["活", "火", "或", "货", "获"],
        "ji": ["几", "机", "己", "及", "即", "级", "集", "记"],
        "jia": ["家", "加", "假", "价", "甲", "嫁"],
        "jian": ["见", "间", "建", "件", "简", "剑", "检"],
        "jiang": ["将", "讲", "江", "降", "奖"],
        "jiao": ["叫", "教", "交", "脚", "角"],
        "jie": ["就", "接", "街", "节", "姐", "解", "借"],
        "jin": ["进", "今", "近", "金", "紧", "尽", "仅"],
        "jing": ["经", "京", "精", "景", "竟", "静", "净"],
        "jiu": ["就", "九", "酒", "旧", "久", "救"],
        "ju": ["举", "句", "局", "具", "剧", "据"],
        "juan": ["卷", "捐", "倦"],
        "jue": ["觉", "决", "绝", "角"],
        "jun": ["军", "均", "君"],
        "ka": ["卡", "咖", "喀"],
        "kai": ["开", "凯", "慨"],
        "kan": ["看", "砍", "刊", "堪"],
        "kang": ["康", "抗", "扛"],
        "kao": ["考", "靠", "烤"],
        "ke": ["可", "课", "克", "客", "科", "刻"],
        "ken": ["肯", "恳", "啃"],
        "kong": ["空", "控", "孔", "恐"],
        "kou": ["口", "扣", "寇"],
        "ku": ["苦", "哭", "库", "酷"],
        "kua": ["夸", "跨", "垮"],
        "kuai": ["快", "块", "会", "筷"],
        "kuan": ["宽", "款"],
        "kuang": ["况", "狂", "矿", "框"],
        "kun": ["困", "昆", "捆"],
        "kuo": ["扩", "括", "阔"],
        "la": ["拉", "啦", "辣"],
        "lai": ["来", "赖"],
        "lan": ["蓝", "懒", "烂", "兰"],
        "lang": ["浪", "朗", "郎", "狼"],
        "lao": ["老", "劳", "牢"],
        "le": ["了", "乐", "勒"],
        "lei": ["类", "累", "雷", "泪"],
        "leng": ["冷", "愣"],
        "li": ["里", "理", "力", "利", "立", "例", "离"],
        "lian": ["连", "练", "脸", "联", "恋"],
        "liang": ["两", "亮", "量", "良", "凉"],
        "liao": ["了", "料", "聊", "辽"],
        "lie": ["列", "烈", "猎", "裂"],
        "lin": ["林", "临", "淋", "邻"],
        "ling": ["领", "零", "令", "灵", "另"],
        "liu": ["六", "留", "流", "刘", "柳"],
        "long": ["龙", "笼", "弄", "隆"],
        "lou": ["楼", "漏", "露"],
        "lu": ["路", "录", "陆", "露", "鹿"],
        "lv": ["绿", "律", "率", "旅"],
        "luan": ["乱", "卵"],
        "lun": ["论", "轮", "伦"],
        "luo": ["落", "罗", "洛", "骆"],
        "ma": ["吗", "妈", "马", "麻", "骂"],
        "mai": ["买", "卖", "麦", "埋"],
        "man": ["满", "慢", "蛮", "瞒"],
        "mang": ["忙", "茫", "盲"],
        "mao": ["猫", "毛", "帽", "冒", "贸"],
        "me": ["么", "什"],
        "mei": ["没", "美", "每", "妹", "梅"],
        "men": ["们", "门", "闷"],
        "meng": ["梦", "猛", "蒙", "萌"],
        "mi": ["米", "密", "秘", "迷", "蜜"],
        "mian": ["面", "免", "棉", "眠"],
        "miao": ["秒", "妙", "苗", "描"],
        "min": ["民", "敏", "闽"],
        "ming": ["名", "明", "命", "鸣"],
        "mo": ["没", "末", "默", "摸", "磨", "模"],
        "mou": ["某", "谋", "牟"],
        "mu": ["目", "木", "母", "幕", "墓"],
        "na": ["那", "拿", "哪", "呐"],
        "nai": ["奶", "耐", "乃"],
        "nan": ["南", "难", "男", "楠"],
        "nang": ["囊"],
        "nao": ["脑", "闹", "恼"],
        "ne": ["呢", "哪"],
        "nei": ["内", "那"],
        "neng": ["能"],
        "ni": ["你", "泥", "逆", "拟"],
        "nian": ["年", "念", "粘"],
        "niang": ["娘", "酿"],
        "niao": ["鸟", "尿"],
        "nin": ["您"],
        "ning": ["宁", "凝", "拧"],
        "niu": ["牛", "扭", "纽"],
        "nong": ["农", "浓", "弄"],
        "nu": ["女", "努", "怒"],
        "nuan": ["暖"],
        "nuo": ["诺", "挪"],
        "ou": ["欧", "偶", "呕"],
        "pa": ["怕", "爬", "帕", "趴"],
        "pai": ["排", "拍", "派", "牌"],
        "pan": ["盘", "判", "盼", "攀"],
        "pang": ["旁", "胖", "庞"],
        "pao": ["跑", "炮", "泡", "抛"],
        "pei": ["配", "陪", "赔", "培"],
        "pen": ["盆", "喷"],
        "peng": ["朋", "碰", "棚", "捧"],
        "pi": ["批", "皮", "片", "脾", "匹"],
        "pian": ["片", "骗", "便", "偏", "篇"],
        "piao": ["票", "漂", "飘"],
        "pin": ["品", "拼", "贫", "频"],
        "ping": ["平", "苹", "评", "瓶", "凭"],
        "po": ["破", "坡", "婆", "迫", "颇"],
        "pu": ["普", "铺", "朴", "扑", "谱"],
        "qi": ["起", "气", "七", "期", "其", "器", "奇"],
        "qia": ["恰", "掐", "洽"],
        "qian": ["前", "钱", "千", "浅", "签", "牵", "欠"],
        "qiang": ["强", "墙", "枪", "抢"],
        "qiao": ["桥", "巧", "敲", "瞧", "悄"],
        "qie": ["切", "且", "窃", "茄"],
        "qin": ["亲", "勤", "琴", "秦", "侵"],
        "qing": ["请", "清", "情", "青", "轻", "庆"],
        "qiong": ["穷", "琼"],
        "qiu": ["求", "球", "秋", "丘"],
        "qu": ["去", "取", "区", "曲", "趣"],
        "quan": ["全", "权", "劝", "圈", "泉"],
        "que": ["却", "确", "缺", "雀"],
        "qun": ["群", "裙"],
        "ran": ["然", "燃", "染"],
        "rang": ["让", "嚷"],
        "rao": ["绕", "扰", "饶"],
        "re": ["热", "惹"],
        "ren": ["人", "认", "任", "忍", "仁"],
        "reng": ["仍", "扔"],
        "ri": ["日"],
        "rong": ["容", "融", "荣", "溶"],
        "rou": ["肉", "柔", "揉"],
        "ru": ["如", "入", "乳", "儒"],
        "ruan": ["软", "阮"],
        "rui": ["瑞", "锐", "睿"],
        "run": ["润", "闰"],
        "ruo": ["若", "弱"],
        "sa": ["撒", "洒", "萨"],
        "sai": ["赛", "塞", "腮"],
        "san": ["三", "散", "伞"],
        "sang": ["桑", "嗓", "丧"],
        "sao": ["扫", "骚", "嫂"],
        "se": ["色", "涩", "瑟"],
        "sen": ["森"],
        "sha": ["杀", "沙", "傻", "啥"],
        "shai": ["晒"],
        "shan": ["山", "善", "闪", "扇", "删"],
        "shang": ["上", "伤", "商", "尚", "赏"],
        "shao": ["少", "烧", "绍", "哨"],
        "she": ["社", "舍", "设", "蛇", "射"],
        "shei": ["谁"],
        "shen": ["什", "身", "深", "神", "生", "审"],
        "sheng": ["生", "声", "省", "胜", "剩", "圣"],
        "shi": ["是", "时", "事", "十", "实", "使", "世", "市", "师"],
        "shou": ["手", "收", "首", "受", "瘦", "守"],
        "shu": ["书", "数", "树", "输", "属", "术", "束"],
        "shua": ["刷", "耍"],
        "shuai": ["帅", "摔", "衰", "甩"],
        "shuan": ["拴", "栓"],
        "shuang": ["双", "爽"],
        "shui": ["水", "睡", "谁", "税"],
        "shun": ["顺", "瞬"],
        "shuo": ["说", "硕"],
        "si": ["四", "思", "死", "似", "私", "丝", "寺"],
        "song": ["送", "松", "宋", "颂"],
        "sou": ["搜", "艘", "嗽"],
        "su": ["苏", "素", "速", "诉", "宿"],
        "suan": ["算", "酸", "蒜"],
        "sui": ["虽", "随", "岁", "碎", "隧"],
        "sun": ["孙", "损", "笋"],
        "suo": ["所", "锁", "缩"],
        "ta": ["他", "她", "它", "塔", "踏"],
        "tai": ["太", "台", "抬", "态", "泰"],
        "tan": ["谈", "弹", "坦", "叹", "探", "碳"],
        "tang": ["堂", "糖", "汤", "躺", "唐"],
        "tao": ["套", "逃", "桃", "讨", "陶"],
        "te": ["特"],
        "teng": ["疼", "腾"],
        "ti": ["提", "题", "体", "替", "踢"],
        "tian": ["天", "田", "甜", "填", "添"],
        "tiao": ["条", "跳", "挑", "调"],
        "tie": ["铁", "贴"],
        "ting": ["听", "停", "挺", "厅", "庭"],
        "tong": ["同", "通", "痛", "统", "铜", "童"],
        "tou": ["头", "偷", "投", "透"],
        "tu": ["图", "土", "突", "吐", "涂", "兔"],
        "tuan": ["团", "湍"],
        "tui": ["退", "推", "腿"],
        "tun": ["吞", "屯"],
        "tuo": ["拖", "脱", "托", "妥"],
        "wa": ["挖", "哇", "蛙", "瓦", "袜"],
        "wai": ["外", "歪"],
        "wan": ["万", "完", "玩", "晚", "碗", "湾"],
        "wang": ["王", "网", "望", "忘", "往"],
        "wei": ["为", "位", "未", "味", "围", "微", "卫"],
        "wen": ["问", "文", "闻", "温", "稳"],
        "wo": ["我", "握", "窝"],
        "wu": ["五", "无", "物", "务", "误", "武", "午"],
        "xi": ["西", "系", "习", "喜", "细", "希", "洗", "席"],
        "xia": ["下", "夏", "吓", "虾", "瞎", "峡"],
        "xian": ["先", "现", "线", "限", "鲜", "闲", "显", "县"],
        "xiang": ["想", "向", "像", "象", "相", "香", "箱", "响"],
        "xiao": ["小", "笑", "校", "消", "效", "晓"],
        "xie": ["写", "些", "谢", "鞋", "血", "斜", "协"],
        "xin": ["新", "心", "信", "辛", "欣", "薪"],
        "xing": ["行", "性", "星", "型", "形", "姓", "兴", "醒"],
        "xiong": ["兄", "胸", "雄", "熊"],
        "xiu": ["修", "休", "秀", "袖"],
        "xu": ["需", "许", "续", "虚", "序"],
        "xuan": ["选", "宣", "悬", "旋", "玄"],
        "xue": ["学", "雪", "血", "穴"],
        "xun": ["训", "寻", "讯", "巡", "迅"],
        "ya": ["呀", "压", "牙", "鸭", "雅"],
        "yan": ["眼", "言", "严", "研", "盐", "颜", "烟", "演"],
        "yang": ["样", "阳", "养", "洋", "央"],
        "yao": ["要", "药", "摇", "遥", "腰", "邀"],
        "ye": ["也", "业", "夜", "叶", "野", "页"],
        "yi": ["一", "以", "已", "意", "易", "亿", "义", "艺", "议"],
        "yin": ["因", "音", "引", "银", "印", "阴", "饮"],
        "ying": ["应", "影", "英", "营", "硬", "迎", "赢", "映"],
        "yong": ["用", "永", "勇", "拥", "涌"],
        "you": ["有", "又", "由", "友", "右", "油", "游", "优"],
        "yu": ["与", "于", "鱼", "语", "雨", "余", "预", "域", "玉"],
        "yuan": ["远", "原", "员", "园", "元", "源", "院", "愿"],
        "yue": ["月", "越", "约", "乐", "阅", "悦"],
        "yun": ["云", "运", "允", "孕", "韵"],
        "za": ["杂", "砸"],
        "zai": ["在", "再", "载", "灾"],
        "zan": ["咱", "赞", "暂"],
        "zang": ["脏", "藏", "葬"],
        "zao": ["早", "造", "糟", "遭", "枣"],
        "ze": ["则", "责", "择", "泽"],
        "zen": ["怎"],
        "zeng": ["增", "曾", "赠"],
        "zha": ["炸", "扎", "渣", "眨"],
        "zhai": ["摘", "窄", "债", "宅"],
        "zhan": ["站", "占", "战", "展", "张"],
        "zhang": ["张", "长", "章", "账", "涨", "掌"],
        "zhao": ["找", "照", "招", "赵", "着"],
        "zhe": ["这", "者", "着", "折", "哲"],
        "zhen": ["真", "阵", "针", "镇", "振"],
        "zheng": ["正", "整", "政", "争", "证", "征"],
        "zhi": ["只", "知", "之", "直", "值", "指", "纸", "至", "制", "志"],
        "zhong": ["中", "种", "重", "众", "终", "钟"],
        "zhou": ["周", "州", "洲", "粥", "轴"],
        "zhu": ["主", "住", "注", "助", "祝", "著", "猪", "竹", "柱"],
        "zhua": ["抓"],
        "zhuai": ["拽"],
        "zhuan": ["转", "专", "砖", "赚"],
        "zhuang": ["装", "状", "壮", "撞"],
        "zhui": ["追", "坠", "缀"],
        "zhun": ["准", "谆"],
        "zhuo": ["桌", "捉", "着"],
        "zi": ["字", "自", "子", "紫", "资", "仔"],
        "zong": ["总", "综", "宗", "纵", "棕"],
        "zou": ["走", "奏", "邹"],
        "zu": ["足", "族", "组", "祖", "阻"],
        "zuan": ["钻"],
        "zui": ["最", "嘴", "醉", "罪"],
        "zun": ["尊", "遵"],
        "zuo": ["做", "作", "坐", "左", "座"],

        // Common phrases
        "nihao": ["你好"],
        "xiexie": ["谢谢"],
        "zaijian": ["再见"],
        "duibuqi": ["对不起"],
        "meiguanxi": ["没关系"],
        "zhongguo": ["中国"],
        "meiguo": ["美国"],
        "beijing": ["北京"],
        "shanghai": ["上海"],
        "shijie": ["世界"],
        "dianhua": ["电话"],
        "diannao": ["电脑"],
        "shouji": ["手机"],
        "gongzuo": ["工作"],
        "xuexiao": ["学校"],
        "xuesheng": ["学生"],
        "laoshi": ["老师"],
        "pengyou": ["朋友"],
        "jiaren": ["家人"],
        "shijian": ["时间"],
        "mingzi": ["名字"],
        "xihuan": ["喜欢"],
        "zhidao": ["知道"],
        "juede": ["觉得"],
        "renwei": ["认为"],
        "kaishi": ["开始"],
        "jieshu": ["结束"],
        "yinwei": ["因为"],
        "suoyi": ["所以"],
        "danshi": ["但是"],
        "ruguo": ["如果"],
        "huanying": ["欢迎"],
        "xianzai": ["现在"],
        "yiqian": ["以前"],
        "yihou": ["以后"],
        "jintian": ["今天"],
        "mingtian": ["明天"],
        "zuotian": ["昨天"],
        "dianying": ["电影"],
        "yinyue": ["音乐"],
        "meishi": ["美食"],
        "lvxing": ["旅行"],
        "jiankang": ["健康"],
        "kuaile": ["快乐"],
        "xingfu": ["幸福"],
        "chenggong": ["成功"]
    ]
    // swiftlint:enable line_length
}
