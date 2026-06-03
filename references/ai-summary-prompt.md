# AI 总结 Prompt 模板（给 LLM agent 用）

> 你的 agent 读完 `transcript_formatted.md`（Part A）后，按本模板拼装 prompt，调用你自己的 LLM 生成 Part B 总结。

## 工作流（agent 视角）

1. 读 `transcript_formatted.md`（Part A，含说话人标注和时间戳的逐字稿）
2. 提取元数据（标题、时长、嘉宾、来源链接）——如果 `transcript.md` 头部已经有就直接用
3. 按下方模板拼装 prompt
4. 用你的 LLM（不限制模型，Anthropic / OpenAI / Gemini / 本地模型都行）调总结
5. 把生成的 Part B 替换 `transcript.md` 中的 Part B 占位
6. 输出最终 `transcript.md`（Part A + Part B 拼装完成）

## 模板

```text
你是一个播客内容分析师。请处理以下小宇宙 (xiaoyuzhoufm.com) 播客的转写内容，生成两部分输出。

【节目元数据】
标题: <TITLE>
时长: <DURATION_MIN> 分钟
来源: <SOURCE_URL>
嘉宾: <GUESTS>  (从转写中识别)

【转写内容】
<TRANSCRIPT_FORMATTED_MD 的完整内容，已含说话人标注 + [MM:SS] 时间戳>

【输出要求】

## Part A — 带说话人标注的完整转写（修正版，仅修正不重写）

格式: **[MM:SS] 说话人名**: 对话内容

规则:
- 在原 transcript 基础上只修正关键错误（人名/公司名/技术术语）
- 不要逐句重复全部 transcript，引用即可
- 说话人优先用关键词表中的实名（参考 speakers/<podcast>.json）
- 不确定的修正标注【疑似误识：原文】
- 时间戳用 [MM:SS] 格式

## Part B — 结构化总结（核心产出）

### 基本信息
- 标题：
- 主播：
- 嘉宾：
- 时长：

### 完整节目简介
(2-3 段话概括本期核心内容)

### 章节时间线
(每段 [MM:SS] + 一句话摘要，5-8 段)

### 核心要点（按主题分组，3-5 组）
### 1. [主题一]
- 要点 + 说话人
### 2. [主题二]
- 要点 + 说话人

### 关键金句（3-5 句，带说话人标注）
> 「金句内容」 —— 说话人名

### 关键问答（3-5 对 Q&A）
**Q1**: 问题？
**A1**: 回答（注明说话人）

请直接输出 Part A 和 Part B 两个 markdown 块，不要开场白或解释。
Part A 用 `## Part A` 开头，Part B 用 `## Part B` 开头。
```

## 错误修正判断规则

| 情况 | 处理方式 |
|------|---------|
| 人名/公司名/技术术语明显错误 | 直接修正 |
| ASR 输出的语言标记行（`Chinese` / `English`） | 直接删除，不出现在最终输出 |
| 不确定的人名/术语 | 标注【疑似误识：原文】 |
| 语气词重复（如"对对对对"） | 精简为"对对"，不改原意 |
| 话题切换点 | 在 Part A 中自然分段，Part B 时间线独立反映 |

## 设计要点

1. **说话人标注**：靠对话内容（称呼、语气、话题切换）分配，不是硬编码
2. **错误修正**：只做小修，不重写 Part A
3. **上下文注入**：播客元数据作为背景，**不搜其他播客**
4. **主题分组** vs 平铺：长播客（>30 分钟）主题分组收益显著
5. **Part A 不重写**：Part A 已经在 `transcript_formatted.md` 里机械生成好，LLM 只做修正 + Part B

## 拼装最终输出

LLM 输出 Part A + Part B 后，agent 拼装成：

```markdown
# <标题>
**源链接**: <URL>
**处理时间**: <TIMESTAMP>

---

## Part A — 带说话人标注的完整转写
<LLM 修正后的 Part A>

---

## Part B — 结构化总结
<LLM 生成的 Part B>
```

把这份 markdown 给用户——他自己决定怎么用（粘 Notion / Obsidian / 飞书 web / Word / 任何下游）。
