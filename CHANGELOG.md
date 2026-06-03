# Changelog

## 1.0.0 (2026-06-03)

初始发布。

### 功能

- Step 1: DashScope 异步 ASR (`qwen3-asr-flash-filetrans`)
- Step 2: 说话人关键词匹配 + 时间戳格式化 (纯 Python, 零 LLM)
- Step 3: LLM 生成 Part B 结构化总结 (直接 curl 调 MiniMax Anthropic API)
- 关键词表驱动说话人识别（支持自定义新播客）
- 主题分组 + 章节时间线 + 关键金句 + Q&A 输出

### 端到端性能

- 60 分钟播客实测 ~2.5 分钟跑完全流程
- Step 1 ASR: ~70 秒
- Step 2 格式化: <1 秒
- Step 3 LLM: ~75 秒

### 依赖

- DashScope API key (设置在 `~/.hermes/.env`)
- 系统工具: `curl`, `jq`, Python ≥ 3.8

### 已知限制

- 模式 A 文件 URL 必须公网可达
- 小宇宙 mediaKey 过期后旧链接 404
- 无 speaker diarization，靠关键词表 + LLM 推断
- 仅支持小宇宙链接（B站/YouTube 不在范围内）
