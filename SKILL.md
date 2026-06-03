---
name: xiaoyuzhou-transcribe
description: 小宇宙 (XiaoyuzhouFM) 播客转写 + AI 总结。输入播客链接，端到端输出 Part A（带说话人标注的完整转写）+ Part B（主题分组结构化总结）的本地 markdown 文件。**通用 skill：输出 markdown 后由用户自行处理（粘 Notion / Obsidian / 任何目标）**。
triggers:
  - 小宇宙链接
  - xiaoyuzhoufm.com/episode/
  - 播客转写
  - 音频转文字
  - podcast to markdown
---

# xiaoyuzhou-transcribe

小宇宙 (xiaoyuzhoufm.com) 播客一键转写 + AI 总结 → 本地 markdown。

> 当前唯一 ASR 后端：**DashScope 异步 URL 模式**（`qwen3-asr-flash-filetrans`）—— 传音频公网 URL 给云端处理，不下载到本地、支持 8 小时长音频、不消耗 CPU。

## 快速开始

```bash
bash scripts/pipeline.sh "https://www.xiaoyuzhoufm.com/episode/xxx" \
    --title "标题"
```

输出: `/tmp/xy_pipeline_<timestamp>/transcript.md`（Part A + Part B 拼装完成）

## 端到端流程

```
小宇宙链接
  ↓ Step 1: transcribe_async.sh
  → 解析 HTML 提取 media.xyzcdn.net 公网 URL
  → POST DashScope 异步 API (qwen3-asr-flash-filetrans)
  → 10s 轮询 → SUCCEEDED 拿 transcription_url
  → 下载 JSON (~70s, 60 分钟音频实测)
  ↓ Step 2: format_transcript.py
  → 说话人关键词匹配 + [MM:SS] 时间戳 + 300字分段 (纯 Python, 零 LLM)
  ↓ Step 3: summarize_transcript.sh
  → 直接 curl 调 MiniMax Anthropic 协议 API
  → LLM 只生成 Part B 总结 (~2K tokens, ~75s)
  ↓
本地 markdown 输出: transcript.md (Part A + Part B 拼装)
```

**端到端 ~2.5 分钟**（60 分钟播客实测）。

## 输出位置

跑完会在 `/tmp/xy_pipeline_<timestamp>/` 留下：

```
transcript.md              # Part A + Part B 拼装 (主输出)
transcript_raw.json        # Step 1 原始 ASR 输出
transcript_formatted.md    # Step 2 说话人 + 时间戳
transcript_final.md        # Step 3 LLM 总结
```

主输出 `transcript.md` 是**自包含**的——直接打开看、粘到任何 markdown 渲染器 / 笔记软件 / 文档系统都可以。

## 下游使用（用户决定）

skill 在 `transcript.md` 阶段停住，**不预设任何下游目标**。常见用途：

- 粘到 Notion / Obsidian / 飞书文档 web 版
- 渲染成 HTML / PDF（pandoc / md-to-pdf）
- git 入库（个人播客笔记仓库）
- 喂给其他 AI 工具做二次分析
- 写进 Word / Google Docs（粘进去即可）
- 任何 markdown 接收器

## 核心脚本

| 路径 | 作用 |
|------|------|
| `scripts/pipeline.sh` | **一键全链路**：小宇宙链接 → 本地 markdown (Step 1-3 wrapper) |
| `scripts/transcribe_async.sh` | 解析链接 + DashScope 异步 API + 轮询 + 下载 |
| `scripts/format_transcript.py` | JSON → Markdown：说话人 + 时间戳 + 分段 |
| `scripts/summarize_transcript.sh` | 直接 curl LLM API 生成 Part B 总结 |
| `speakers/silicon101.json` | 关键词表示例（泓君/傅盛/徐老师）|

## ASR 后端：DashScope 异步 URL 模式

- **API 端点**: `POST https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription`
- **模型**: `qwen3-asr-flash-filetrans`
- **核心优势**: 传公网 URL 给云端，**不下载到本地**、**不走 VAD 切片**、**不消耗 CPU**、**不受 server→CDN 速度影响**
- **支持时长**: ≤ 8 小时
- **输出**: `sentences[]` 含毫秒级 `begin_time / end_time / language / emotion`

```bash
bash scripts/transcribe_async.sh "https://www.xiaoyuzhoufm.com/episode/xxx" /tmp/raw.json
```

**协议详情**: `references/dashscope-async-filetrans.md`

### 模式 B：本地 Toolkit 同步（兜底）

仅适用于音频**已经是本地文件**的场景（其他机器 scp 过来、用户提供的录音）：

```bash
$(command -v qwen3-asr || echo /root/.hermes/hermes-agent/venv/bin/qwen3-asr) \
  --input-file /tmp/<audio> \
  --dashscope-api-key "$DASHSCOPE_API_KEY" \
  --num-threads 2 --save-srt
```

## 说话人检测（关键词表）

`format_transcript.py` 读取 `speakers/<podcast>.json` 关键词表，匹配"我是XXX"等自我介绍段切换 speaker。

**添加新播客**: 复制 `silicon101.json` 改名字 + 关键词列表即可，**不需要改脚本**。详见 `references/speaker-detection-strategies.md`。

## Part A / Part B 输出格式

### Part A — 完整转写（format_transcript.py 生成）

```markdown
**泓君** [00:00]
嗨，大家好，欢迎收听硅谷101，我是红军...

**泓君** [01:02]
2026年的香港共识大会...
```

格式：`[MM:SS] 说话人：内容`，300 字自动分段。专有名词由 Step 3 LLM 二次修正。

### Part B — 结构化总结（summarize_transcript.sh 生成）

```markdown
## 📌 核心要点

### 1. [主题一：量产与商业化]
- 傅盛：2021 年预言特斯拉量产 10 万台做不到，2025 年实际只做了几千台
- Atlas 宣布 2028 年达 3 万台产能，被质疑"宣布量产意义不大"

### 2. [主题二：硬件与成本]
- 猎豹收购 U Factory 把六轴臂从 10 万降到 4000-5000 美金
```

**主题分组** vs 平铺：分组更适合跨播客主题聚合。LLM 多花几十 token 分组，长播客 (>30 分钟) 收益显著。

完整 prompt 模板: `references/ai-summary-prompt.md`

## 已知限制

1. **模式 A 文件 URL 必须公网可达**：私网 / 鉴权 URL 失败。小宇宙 `media.xyzcdn.net` 公开 URL 没问题。
2. **小宇宙 mediaKey 过期**：签名 URL 含时间戳，几个月前链接 404，需重新从 HTML 提取。
3. **无 speaker diarization**：所有 ASR 方案均不支持，靠关键词表 + LLM 推断说话人。
4. **关键词表说话人识别有限**：仅识别**自我介绍段**（"我是XXX"），对话中段只能标"主持人"或保留上次识别。需要 LLM 第二阶段处理才能完整归类。
5. **B站/YouTube 不在本 skill 范围**：本 skill 专攻小宇宙链接。

## 依赖

```bash
# 系统
curl, jq

# Python (format_transcript.py 仅用标准库)
python3 ≥ 3.8

# 凭据
# DASHSCOPE_API_KEY 在 ~/.hermes/.env 或环境变量
# 申请: https://dashscope.console.aliyun.com/apiKey
```

**skill 不需要 lark-cli / 飞书 SDK / Notion API / 任何下游系统**——输出是纯 markdown。

## 参考

- Qwen3-ASR Toolkit: https://github.com/QwenLM/Qwen3-ASR-Toolkit
- DashScope 文档: https://help.aliyun.com/zh/dashscope/

## 文档索引

| 文档 | 何时读 |
|------|--------|
| `references/dashscope-async-filetrans.md` | 改 ASR 集成时 |
| `references/ai-summary-prompt.md` | 改 Part B prompt 模板时 |
| `references/llm-summarize-pitfalls.md` | 排查 LLM 总结质量问题时 |
| `references/speaker-detection-strategies.md` | 改说话人识别逻辑时 |
