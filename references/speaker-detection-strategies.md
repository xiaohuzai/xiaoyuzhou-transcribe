# 说话人检测策略：关键词 vs LLM 双轨

> 当前所有 ASR 模型（Qwen3-ASR / Whisper / Paraformer）**均不支持 speaker diarization**。必须后处理识别说话人。

## 双轨方案

| 轨道 | 实现 | 优点 | 缺点 |
|------|------|------|------|
| **A. 关键词表** | `format_transcript.py` 纯 Python 匹配 "我是XXX" | 零 token 消耗、确定性、可重跑 | 关键词未出现则识别失败；写死需要编辑脚本 |
| **B. LLM 推断** | Step 3 AI 处理阶段，让 LLM 根据对话内容/语气/称呼分配 | 灵活、识别新嘉宾能力强；可处理模糊指代 | 消耗 token、不可重跑（每次结果可能微调）、依赖 prompt 质量 |

**实际工作流**：
1. **优先跑轨道 A**（关键词表）—— 出 baseline 标注
2. **再跑轨道 B**（LLM 推断）—— 覆盖轨道 A 没识别出来的 + 修正错配
3. **人工 sanity check**（可选）—— 长播客（> 60 分钟）建议看一遍 5-10 个随机段落

## 关键词表设计原则

### 应该包含的 marker
- ✅ **自我介绍**："我是XXX"、"XXX 你好"
- ✅ **被称呼**："傅盛总"、"徐老师"、"泓君"
- ✅ **多人对话的客套语**："hello 大家好我是XXX"
- ✅ **同音不同字**：常见 ASR 误识也要包含（如"郑豪"≈"真豪"≈"祯豪"）

### 不应该包含的
- ❌ **太宽泛**："主持人"（本身就是 fallback，匹配会覆盖真实名字）
- ❌ **单字**：误识率太高
- ❌ **专业术语**：避免跟内容主题冲突

### 维护策略

**触发更新**：
- 新增常驻嘉宾（5+ 次出现）→ 加进默认表
- ASR 反复误识某个名字 → 加变体 marker
- 老嘉宾离开 → 不删（历史节目还有用）

**关键词表存放位置**（2026-06-01 升级）：
- **外部 JSON 文件**：`speakers/<播客名>.json`（相对 skill 根目录），如 `speakers/silicon101.json`
- **格式**：以说话人姓名为 key，marker 列表为 value；`_` 前缀的 key（如 `_comment`、`_usage`）作为注释，会被自动跳过
- **调用方式**：`python3 scripts/format_transcript.py raw.json out.md --speakers speakers/silicon101.json`

**默认 fallback 表**（脚本内置，4 个历史嘉宾，无外部文件时使用）：
```python
speaker_markers = {
    '刘一鸣': ['我是刘一鸣', '我是特约研究员刘一鸣', '我是一鸣'],
    '知县': ['我是知县', '大家好我是知线', '我是知线', '大家好，我是知县'],
    '华祯豪': ['我是郑豪', '我是真豪', 'Hello大家好我是郑豪', '我是华祯豪'],
    '叶天奇': ['我是天奇', '我是叶天奇', '大家好，我是天奇'],
}
```

**硅谷101 外部表示例**（`speakers/silicon101.json`）：
```json
{
  "_comment": "硅谷101 关键词表",
  "_usage": "format_transcript.py raw.json out.md --speakers speakers/silicon101.json",
  "泓君": ["我是红军", "我是泓君", "大家好欢迎收听硅谷101"],
  "傅盛": ["我是傅盛", "傅盛你好", "傅盛总", "Hello，傅盛"],
  "硅谷徐老师": ["我是徐老师", "硅谷徐老师", "徐老师你好", "Hello，徐老师"]
}
```

> 📌 **2026-06-01 测试**：硅谷101 一期 38 分钟音频（红军+傅盛+徐老师聊 CES），关键词表对**所有自我介绍段**都识别成功，对话中段只能标"主持人"。

## LLM 推断的 Prompt 设计

**关键要素**（参考 `references/ai-summary-prompt.md`）：

1. **注入嘉宾名单**（元数据里的"嘉宾"字段）
2. **注入频道特征**（如"硅谷101 是科技类播客"）
3. **说话人判断规则**：
   - 介绍新嘉宾时是主持人
   - 嘉宾通常有专业术语习惯（"我做了 20 年机器人"）
   - 问"你怎么看"时是在切换发言权
4. **不确定时怎么处理**：
   - 关键词表已识别的 → 保留
   - 多人对话难分 → 标"对话"或"嘉宾A/B"
   - 标【疑似说话人：XXX】让用户核对

## 进阶：speaker embedding + 聚类

**如果**你真的需要精确 diarization：

1. **pyannote.audio**（开源 SOTA，Python 库）
   - 原理：speaker embedding → 谱聚类 → 时间戳对齐
   - 质量：⭐⭐⭐⭐⭐
   - 代价：本地 GPU / CPU 密集（**不能在 server 上跑**，会吃光资源）
   - 替代：批量任务丢给 MacBook 本地跑

2. **DashScope Paraformer + diarization**（阿里自家）
   - 闭源，API 计费
   - 质量：⭐⭐⭐⭐
   - 代价：要单独申请 + 集成

**当前决策**：不值得为 podcast 转写单独搞。关键词 + LLM 双轨已覆盖 90% 场景，剩下 10% 人工 sanity check 更快。

## 调试：识别错的常见原因

| 现象 | 原因 | 修复 |
|------|------|------|
| 全标"主持人" | 关键词表里没这个嘉宾 | 加 marker |
| 嘉宾名错位 | ASR 误识（如"傅盛"→"扶升"） | 加同音字 marker |
| 同一段里 speaker 切了 5+ 次 | 关键词太短误匹配 | 延长 marker 长度 |
| LLM 推断跟关键词表冲突 | Prompt 没强调"关键词优先" | Prompt 加约束 |

## 当前 skill 实现位置

- **关键词表轨道 A**：`scripts/format_transcript.py` 的 `speaker_markers` 字典
- **LLM 推断轨道 B**：`references/ai-summary-prompt.md` 的 Part A prompt
