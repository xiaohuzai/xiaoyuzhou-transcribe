#!/usr/bin/env bash
# summarize_transcript.sh — 调用 LLM 做播客双阶段处理
#
# 输入: /tmp/transcript_formatted.md (Part A 说话人标注的逐字稿)
# 输出: /tmp/transcript_final.md (Part A 修正版 + Part B 结构化总结)
#
# 用法: bash summarize_transcript.sh <input_md> <output_md> [metadata_json]
#
# 关键设计 (2026-06-01):
#   - 用直接 curl 调 MiniMax LLM API (绕过 hermes chat CLI, 支持 max_tokens)
#   - 端点: https://api.minimaxi.com/anthropic/v1/messages (Anthropic 协议)
#   - max_tokens=4000 限制输出长度, 防止 8+ 分钟 timeout
#   - 拆策略: Part A 由 format_transcript.py 生成, LLM 只输出 Part B
#   - 2026-06-02 升级: MapReduce 跨 30K 截断 (拆 2 段 + Reduce 合并)
#   - 输入 30K 字符 (MAX_INPUT_CHARS), 超过则拆段调 LLM

set -euo pipefail

# ---------- 参数 ----------
INPUT_MD="${1:-/tmp/transcript_formatted.md}"
OUTPUT_MD="${2:-/tmp/transcript_final.md}"
META_JSON="${3:-/tmp/transcript_meta.json}"

if [ ! -f "$INPUT_MD" ]; then
    echo "❌ 输入文件不存在: $INPUT_MD" >&2
    exit 1
fi

# ---------- 环境 ----------
# 加载 DASHSCOPE_API_KEY (兼容自定义 HERMES_HOME)
[ -f "${HERMES_HOME:-$HOME/.hermes}/.env" ] && source "${HERMES_HOME:-$HOME/.hermes}/.env" 2>/dev/null || true
API_KEY="${MINIMAX_CN_API_KEY:-${ANTHROPIC_API_KEY:-}}"
if [ -z "$API_KEY" ]; then
    echo "❌ MINIMAX_CN_API_KEY 未设置" >&2
    exit 1
fi
LLM_URL="https://api.minimaxi.com/anthropic/v1/messages"
LLM_MODEL="MiniMax-M3"
MAX_TOKENS=4000   # 限制输出长度
MAX_INPUT_CHARS=30000  # 单次 LLM 调用输入字符数阈值 (Prompt 模板占 ~3K, 实际 transcript 限制 ~27K)
# ⚠️ 中文字符 3 字节, 用 chars 数 (≠ bytes) 更接近 LLM token 数
CHUNK_TARGET_CHARS=22000  # MapReduce 拆段目标 (留余量给 prompt 模板 + 元数据)

# ---------- 读取输入 ----------
# 清洗: 去除 surrogate pair (LLM API 不接受)
INPUT_CONTENT=$(cat "$INPUT_MD" | python3 -c "
import sys
data = sys.stdin.buffer.read().decode('utf-8', errors='replace')
data = data.encode('utf-8', errors='replace').decode('utf-8', errors='replace')
print(data, end='')
")
INPUT_TRUNCATED=false
ORIG_SIZE=${#INPUT_CONTENT}
TOTAL_USAGE_INPUT=0
TOTAL_USAGE_OUTPUT=0

if [ "$ORIG_SIZE" -gt "$MAX_INPUT_CHARS" ]; then
    INPUT_TRUNCATED=true
    echo "⚠️ 输入超长 (${ORIG_SIZE} > ${MAX_INPUT_CHARS} chars), 将 MapReduce 拆段" >&2
fi

# 读取元数据 (可选)
META_CONTENT=""
if [ -f "$META_JSON" ]; then
    META_CONTENT=$(cat "$META_JSON" | head -c 1000)
fi

# ---------- 调 LLM 公共函数 ----------
# 用法: call_llm "<prompt_content>" <output_response_file>
# 返回: LLM 响应文本写到 RESPONSE_FILE, usage 累加到全局
call_llm() {
    local prompt_content="$1"
    local response_file="$2"

    local payload_file
    payload_file=$(mktemp /tmp/xy_payload.XXXXXX)
    local tmp_response
    tmp_response=$(mktemp /tmp/xy_resp.XXXXXX)
    trap "rm -f '$payload_file' '$tmp_response'" RETURN

    PROMPT="$prompt_content" PAYLOAD_FILE="$payload_file" LLM_MODEL="$LLM_MODEL" MAX_TOKENS="$MAX_TOKENS" python3 <<'PYEOF'
import json, os
payload = {
    'model': os.environ['LLM_MODEL'],
    'max_tokens': int(os.environ['MAX_TOKENS']),
    'thinking': {'type': 'disabled'},
    'messages': [{'role': 'user', 'content': os.environ['PROMPT']}],
}
with open(os.environ['PAYLOAD_FILE'], 'w') as f:
    json.dump(payload, f, ensure_ascii=False)
PYEOF

    local start_time
    start_time=$(date +%s)
    (
        while true; do
            sleep 5
            local elapsed=$(( $(date +%s) - start_time ))
            echo -n "⏳ ${elapsed}s " >&2
        done
    ) &
    local progress_pid=$!

    local http_code
    http_code=$(curl -s -o "$tmp_response" -w "%{http_code}" \
        --max-time 300 \
        -X POST "$LLM_URL" \
        -H "x-api-key: $API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data-binary "@$payload_file") || http_code="curl_failed"

    kill "$progress_pid" 2>/dev/null || true
    wait "$progress_pid" 2>/dev/null || true
    local elapsed=$(( $(date +%s) - start_time ))
    echo "✓ (${elapsed}s)" >&2

    if [ "$http_code" != "200" ]; then
        echo "❌ LLM API 调用失败 (HTTP $http_code)" >&2
        head -c 500 "$tmp_response" >&2
        echo "" >&2
        return 1
    fi

    # 提取 text block + 写 usage 到临时文件
    # 用 python 脚本读 env 变量, 避免 bash → python 字符串内嵌的引号问题
    local usage_file="/tmp/xy_usage_$$.txt"
    TMP_RESP="$tmp_response" RESP_FILE="$response_file" USAGE_FILE="$usage_file" python3 <<'PYEOF'
import json, os
with open(os.environ['TMP_RESP']) as f:
    d = json.load(f)
content = d.get('content', [])
for block in content:
    if block.get('type') == 'text':
        with open(os.environ['RESP_FILE'], 'w') as f:
            f.write(block.get('text', ''))
        break
u = d.get('usage', {})
with open(os.environ['USAGE_FILE'], 'w') as f:
    f.write(f'{u.get("input_tokens", 0)} {u.get("output_tokens", 0)}')
PYEOF
    if [ -f "$usage_file" ]; then
        # 用 || true 避免 set -e 下 read 返回非零导致脚本退出
        read -r inp outp < "$usage_file" || true
        rm -f "$usage_file"
        # 默认 0 (避免 read 失败时 inp/outp 是上一轮值)
        : "${inp:=0}" "${outp:=0}"
        TOTAL_USAGE_INPUT=$((TOTAL_USAGE_INPUT + inp))
        TOTAL_USAGE_OUTPUT=$((TOTAL_USAGE_OUTPUT + outp))
    fi
}

# ---------- 拼 Part B 模板 ----------
PART_B_PROMPT_TEMPLATE='你是一个播客内容分析师。**Part A（带说话人标注的逐字稿）已经处理好**，你**只需要输出 Part B 结构化总结**。
Part A 输入已包含 `[MM:SS] 说话人名: 内容` 格式的逐字稿，**不要重新输出 Part A 全文**——直接用其内容来生成 Part B 总结即可。

【节目元数据】（如提供）
__META__

【Part A 逐字稿 + 时间戳】（本段约第 __CHUNK_IDX__/__TOTAL_CHUNKS__ 段）
__INPUT__

【输出要求 - 严格遵守】

# 直接以 `## Part B` 开头，**不要再生成 Part A**

## Part B — 结构化总结

### 基本信息
- 标题：（从节目内容推断主题）
- 主播：
- 嘉宾：
- 时长：（从最后一个时间戳推断）
- 播放量：（如未提供写"未提供"）

### 完整节目简介
（2-3 段话概括本期核心内容，300-500 字）

### 章节时间线
（每段 [MM:SS] + 一句话摘要，5-8 段）

### 📌 核心要点（按主题分组，3-5 组）
### 1. [主题一：xxx]
- 要点 + 说话人
### 2. [主题二：xxx]
- 要点 + 说话人

### 关键金句（3-5 句，带说话人标注）
> 「金句内容」 —— 说话人名

### 关键问答（3-5 对 Q&A）
**Q1**: 问题？
**A1**: 回答（注明说话人）

⚠️ **不要再输出 Part A**！只要 Part B 总结。Part A 的逐字稿已经由前置脚本生成好。'

# 拆段函数: 按字符数拆 transcript, 尽量在句子边界断开
# 输出: 每段写到 /tmp/xy_chunk_NNNN.txt
split_into_chunks() {
    local input="$1"
    local target_chars="$2"
    local total_chars=${#input}

    # 计算需要拆几段
    local n_chunks=$(( (total_chars + target_chars - 1) / target_chars ))
    if [ "$n_chunks" -lt 1 ]; then n_chunks=1; fi
    echo "🔪 拆段: 总长 ${total_chars} chars → ${n_chunks} 段 (每段目标 ${target_chars})" >&2

    python3 -c "
import sys
text = '''$input'''
target = $target_chars
n = $n_chunks

# 按段落 (\n\n) 切分, 避免把句子切断
paragraphs = text.split('\n\n')
chunks = [[] for _ in range(n)]
chunk_sizes = [0] * n

# 贪心: 找当前最小 chunk
for para in paragraphs:
    if not para.strip():
        continue
    para_with_sep = para + '\n\n'
    para_len = len(para_with_sep)
    # 找当前最小 chunk 索引
    min_idx = chunk_sizes.index(min(chunk_sizes))
    chunks[min_idx].append(para_with_sep)
    chunk_sizes[min_idx] += para_len

for i, c in enumerate(chunks):
    with open(f'/tmp/xy_chunk_{i:04d}.txt', 'w') as f:
        f.write(''.join(c))
    print(f'  段 {i+1}: {chunk_sizes[i]} chars', file=sys.stderr)
print(n)
"
}

# ---------- 主流程 ----------
TOTAL_USAGE_INPUT=0
TOTAL_USAGE_OUTPUT=0

if [ "$ORIG_SIZE" -le "$MAX_INPUT_CHARS" ]; then
    # === 单次调用 ===
    echo "🤖 调用 LLM (单次, $ORIG_SIZE chars)..." >&2
    PROMPT_CONTENT="${PART_B_PROMPT_TEMPLATE//__META__/$META_CONTENT}"
    PROMPT_CONTENT="${PROMPT_CONTENT//__INPUT__/$INPUT_CONTENT}"
    PROMPT_CONTENT="${PROMPT_CONTENT//__CHUNK_IDX__/1}"
    PROMPT_CONTENT="${PROMPT_CONTENT/__TOTAL_CHUNKS__/1}"

    RESPONSE_FILE="/tmp/xy_final_response.txt"
    call_llm "$PROMPT_CONTENT" "$RESPONSE_FILE"
    RESPONSE=$(cat "$RESPONSE_FILE")

else
    # === MapReduce 拆段 ===
    echo "🤖 调用 LLM (MapReduce 模式, $ORIG_SIZE chars)..." >&2
    N_CHUNKS=$(split_into_chunks "$INPUT_CONTENT" "$CHUNK_TARGET_CHARS" | tail -1)

    # --- Map: 每段调一次 LLM, 收集"段级 Part B 草稿" ---
    declare -a CHUNK_PART_BS=()
    for i in $(seq 0 $((N_CHUNKS - 1))); do
        CHUNK_FILE="/tmp/xy_chunk_$(printf '%04d' $i).txt"
        CHUNK_SIZE=$(wc -c < "$CHUNK_FILE")
        echo "🤖  [Map $((i+1))/$N_CHUNKS] 段级 Part B (${CHUNK_SIZE} chars)..." >&2

        PROMPT_CONTENT="${PART_B_PROMPT_TEMPLATE//__META__/$META_CONTENT}"
        PROMPT_CONTENT="${PROMPT_CONTENT//__INPUT__/$(cat "$CHUNK_FILE")}"
        PROMPT_CONTENT="${PROMPT_CONTENT//__CHUNK_IDX__/$((i+1))}"
        PROMPT_CONTENT="${PROMPT_CONTENT/__TOTAL_CHUNKS__/$N_CHUNKS}"

        CHUNK_RESP="/tmp/xy_chunk_response_$(printf '%04d' $i).txt"
        call_llm "$PROMPT_CONTENT" "$CHUNK_RESP"
        CHUNK_PART_BS+=("$CHUNK_RESP")
    done

    # --- Reduce: 把所有段级 Part B 拼成 Part B 草稿, 让 LLM 合并去重 ---
    echo "🤖  [Reduce] 合并 $N_CHUNKS 段级 Part B 草稿..." >&2
    COMBINED_PARTS=""
    for f in "${CHUNK_PART_BS[@]}"; do
        COMBINED_PARTS="${COMBINED_PARTS}----- 段间分隔 -----
$(cat "$f")
"
    done

    REDUCE_PROMPT="你是一个播客内容分析师。下面是 **$N_CHUNKS 段** 段级 Part B 草稿（来自同一期节目的不同片段），请**合并去重**为一份**最终 Part B 结构化总结**。

# 合并规则
- 保留所有**不重复**的核心要点，主题归并（如两段都讲\"机器人量产\"→ 合并为同一个主题组）
- 章节时间线：拼接 $N_CHUNKS 段的时间线，**按时间排序**，去重相邻段
- 关键金句：选最有代表性的 5-7 句
- 关键问答：选最有价值的 5-7 对
- 基本信息：标题/主播/嘉宾/时长/播放量（取一致项）
- **直接以 \`## Part B\` 开头输出**，格式与段级 Part B 一致

【段级 Part B 草稿】
${COMBINED_PARTS}"

    RESPONSE_FILE="/tmp/xy_final_response.txt"
    call_llm "$REDUCE_PROMPT" "$RESPONSE_FILE"
    RESPONSE=$(cat "$RESPONSE_FILE")
fi

USAGE="input=${TOTAL_USAGE_INPUT} output=${TOTAL_USAGE_OUTPUT}"

# ---------- 验证输出 ----------
echo "🔍 RESPONSE length: ${#RESPONSE}, USAGE: $USAGE" >&2
if [ -z "$RESPONSE" ] || [ ${#RESPONSE} -lt 200 ]; then
    echo "❌ LLM 输出过短 (${#RESPONSE} chars, usage: $USAGE)" >&2
    echo "RESPONSE:" >&2
    echo "$RESPONSE" | head -c 500 >&2
    exit 1
fi

if ! echo "$RESPONSE" | grep -qE "^##\s*Part B"; then
    echo "❌ LLM 输出连 '## Part B' 都没有" >&2
    echo "Response first 500:" >&2
    echo "$RESPONSE" | head -c 500 >&2
    exit 1
fi

# ---------- 写输出 ----------
{
    echo "# 播客内容总结"
    echo ""
    echo "<!-- Generated by xiaoyuzhou-transcribe summarize_transcript.sh -->"
    echo "<!-- Source: $INPUT_MD | Time: $(date -Iseconds) | Usage: $USAGE -->"
    [ "$INPUT_TRUNCATED" = true ] && echo "<!-- ⚠️ MapReduce: 原 ${ORIG_SIZE} chars → ${N_CHUNKS:-1} 段 → Reduce 合并 -->"
    echo ""
    echo "$RESPONSE"
} > "$OUTPUT_MD"

echo "✅ 总结完成: $OUTPUT_MD ($(wc -c < "$OUTPUT_MD") bytes, $USAGE)" >&2
