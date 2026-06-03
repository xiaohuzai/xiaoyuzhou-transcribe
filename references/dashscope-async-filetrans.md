# DashScope 异步转录 API（qwen3-asr-flash-filetrans）

> 适用：DashScope 异步文件转录 API，传音频公网 URL，云端处理不下载到本地。

## 为什么选这个模型

| 维度 | `qwen3-asr-flash-filetrans` | `qwen3-asr` (Toolkit 同步) |
|------|---------------------------|--------------------------|
| 调用方式 | HTTP 异步（轮询 task_id） | 本地 CLI 同步阻塞 |
| 音频传输 | 传 URL，云端拉 | 本地下载 → 切片 → 上传 |
| 长音频 | **8 小时直传** | VAD 切成 ~3 分钟段 |
| 本地磁盘 | **0**（不下载） | 必须先下载完整文件 |
| 本地 CPU | **0** | ffmpeg 切片 + VAD 模型 |
| 网络要求 | server → DashScope 即可 | server → 音频源 CDN |
| 进度反馈 | task_status 轮询 | Python 进程活跃连接数 |

**关键差异**：filetrans **绕过本地所有瓶颈**。当你 server→小宇宙 CDN 慢、磁盘小、CPU 弱时，这个模型最合适。

## API 协议

### 1. 提交任务

```bash
curl -s --location --request POST \
  'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription' \
  --header "Authorization: Bearer ${DASHSCOPE_API_KEY}" \
  --header "Content-Type: application/json" \
  --header "X-DashScope-Async: enable" \
  --data '{
    "model": "qwen3-asr-flash-filetrans",
    "input": {
      "file_url": "https://media.xyzcdn.net/xxx/xxx.mp3"
    },
    "parameters": {
      "channel_id": [0],
      "language": "zh",
      "enable_itn": true
    }
  }'
```

**响应**（提交成功）：

```json
{
  "output": {
    "task_id": "cabb1b58-b64a-451f-a8eb-60f5feb6bb81",
    "task_status": "PENDING"
  },
  "request_id": "..."
}
```

### 2. 轮询任务状态

```bash
curl -s --location --request GET \
  "https://dashscope.aliyuncs.com/api/v1/tasks/${TASK_ID}" \
  --header "Authorization: Bearer ${DASHSCOPE_API_KEY}" \
  --header "Content-Type: application/json"
```

**响应**（任务完成）：

```json
{
  "output": {
    "task_id": "cabb1b58-...",
    "task_status": "SUCCEEDED",
    "result": {
      "transcription_url": "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/xxx?Expires=...",
      "subtask_status": "SUCCEEDED"
    }
  }
}
```

**状态机**：`PENDING` → `RUNNING` → `SUCCEEDED | FAILED`

### 3. 下载结果

```bash
curl -sL "${TRANSCRIPTION_URL}" > /tmp/transcript_raw.json
```

**⚠️ 临时 URL**：transcription_url 是带签名的 OSS URL，**24 小时有效**。处理完尽快拉走。

## 输出 JSON 结构

```json
{
  "transcripts": [
    {
      "channel_id": 0,
      "text": "完整文本...",
      "sentences": [
        {
          "sentence_id": 0,
          "begin_time": 0,           // 毫秒
          "end_time": 38740,         // 毫秒
          "language": "zh",
          "emotion": "neutral",      // 可选字段
          "text": "嗨，大家好..."
        }
      ]
    }
  ]
}
```

**关键字段**：

- `sentences[].begin_time` / `end_time`：毫秒级时间戳，**直接给数字**，比 SRT 格式 `00:01:02,500` 解析方便
- `sentences[].language`：单句语言（混合中英场景很有用）
- `sentences[].emotion`：情绪标签（实测全部返回 `neutral`，质量存疑，不要依赖）
- `text`：完整文本（句子的拼接）

## 轮询策略

| 间隔 | 适用场景 |
|------|---------|
| 5s | 短音频（< 5 分钟），交互式 |
| 10s | 中等音频（5-60 分钟），**推荐** |
| 30s | 长音频（> 1 小时），省 quota |

**超时**：默认 1 小时（3600s）足够 8 小时长音频（实测 60 分钟音频 80 秒内完成）。

## 已知坑

1. **Authorization Bearer token 必须用变量**：硬编码 `***` 字面量会导致 401 鉴权失败。用 `${DASHSCOPE_API_KEY}`。
2. **`set -u` + 未设 `QWEN_API_KEY`**：报 `unbound variable`。兼容补丁：`if [ -z "${DASHSCOPE_API_KEY:-}" ]; then DASHSCOPE_API_KEY="${QWEN_API_KEY:-}"; fi`。
3. **file_url 必须公网可达**：私网 / 鉴权 URL 会失败。**小宇宙的 `media.xyzcdn.net` 是公开的，OK**。
4. **情绪检测（emotion）**：实测全部 neutral，**不要依赖 emotion 字段做情绪分析**。
5. **API key 自动加载**：脚本默认从 `~/.config/xiaoyuzhou-transcribe/.env` 读 `DASHSCOPE_API_KEY`（兼容 `~/.hermes/.env` 和环境变量）。如果换了 env 文件路径或 key 名，需要修脚本里的 `load_api_key()` 函数。

## 适用 vs 不适用场景

| 场景 | 推荐模式 |
|------|---------|
| 小宇宙（任意长度） | ✅ 模式 A 完美 |
| 已是本地 .mp3/.wav 文件 | 模式 B（避免再传一次公网） |
| 私网音频 / 鉴权 URL | 模式 B（filetrans 拉不下来） |
| 超长音频（> 4 小时） | ✅ 模式 A（原生 8h 支持） |
| 实时流 | ❌ 两个模式都不支持 |
