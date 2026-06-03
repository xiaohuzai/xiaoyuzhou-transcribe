#!/usr/bin/env bash
# 小宇宙 / B站 / 任意 .mp3/.m4a URL → DashScope 异步转写
# 使用 Qwen ASR (qwen3-asr-flash-filetrans) 异步模式，支持 8 小时长音频
#
# 用法: ./transcribe_async.sh <xiaoyuzhou_url | audio_url> [output_file]
# 环境变量: DASHSCOPE_API_KEY (必需，兼容 QWEN_API_KEY)
#
# 来源: ychenjk-sudo/xiaoyuzhou-transcription-skill (MIT)
# 适配: hermes xiaoyuzhou-transcribe skill (2026-06-01)
#   - 修复 Bearer token 字面量 *** 替换为 ${DASHSCOPE_API_KEY}
#   - 修复 set -u 下 QWEN_API_KEY unbound variable
# 加载 DASHSCOPE_API_KEY (跨 agent 兼容, 不绑定任何 agent 平台)
# 优先级: 环境变量 > ~/.config/xiaoyuzhou-transcribe/.env > ~/.hermes/.env (hermes 兼容)
if [ -z "${DASHSCOPE_API_KEY:-}" ] && [ -f "$HOME/.config/xiaoyuzhou-transcribe/.env" ]; then
    DASHSCOPE_API_KEY=$(grep -E "^DASHSCOPE_API_KEY=" "$HOME/.config/xiaoyuzhou-transcribe/.env" 2>/dev/null | head -1 | cut -d'=' -f2-)
    export DASHSCOPE_API_KEY
fi
if [ -z "${DASHSCOPE_API_KEY:-}" ] && [ -f "${HERMES_HOME:-$HOME/.hermes}/.env" ]; then
    DASHSCOPE_API_KEY=$(grep -E "^DASHSCOPE_API_KEY=" "${HERMES_HOME:-$HOME/.hermes}/.env" 2>/dev/null | head -1 | cut -d'=' -f2-)
    export DASHSCOPE_API_KEY
fi
export DASHSCOPE_API_KEY
if [ -z "$DASHSCOPE_API_KEY" ]; then
    log_error "请设置环境变量 DASHSCOPE_API_KEY (或 QWEN_API_KEY), 或写入以下任一文件:"
    log_error "  - ~/.config/xiaoyuzhou-transcribe/.env (推荐, 跨 agent)"
    log_error "  - ~/.hermes/.env (Hermes Agent 兼容)"
    exit 1
fi

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 检查依赖
check_deps() {
    local missing=()
    for cmd in curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少依赖: ${missing[*]}"
        log_error "请先安装: apt-get install ${missing[*]}"
        exit 1
    fi
}

# 解析小宇宙页面，提取音频 URL
extract_audio_url() {
    local page_url="$1"
    log_info "提取音频URL: $page_url"

    local html
    html=$(curl -sL --max-time 30 "$page_url")

    local audio_url
    audio_url=$(echo "$html" | grep -oE 'https://media\.xyzcdn\.net/[^"]+\.(mp3|m4a)' | head -1)

    if [ -z "$audio_url" ]; then
        audio_url=$(echo "$html" | grep -oE '"enclosureUrl":"[^"]+"' | head -1 | sed 's/"enclosureUrl":"//;s/"$//')
    fi

    if [ -z "$audio_url" ]; then
        log_error "无法提取音频URL，请检查链接是否有效"
        exit 1
    fi

    echo "$audio_url"
}

# 提交转录任务
submit_task() {
    local audio_url="$1"
    log_info "提交转录任务 (qwen3-asr-flash-filetrans)..."

    local response
    response=$(curl -s --location --max-time 30 --request POST 'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription' \
        --header "Authorization: Bearer ${DASHSCOPE_API_KEY}" \
        --header "Content-Type: application/json" \
        --header "X-DashScope-Async: enable" \
        --data "{
            \"model\": \"qwen3-asr-flash-filetrans\",
            \"input\": {
                \"file_url\": \"$audio_url\"
            },
            \"parameters\": {
                \"channel_id\": [0],
                \"language\": \"zh\",
                \"enable_itn\": true
            }
        }")

    local task_id
    task_id=$(echo "$response" | jq -r '.output.task_id // empty')

    if [ -z "$task_id" ]; then
        log_error "提交任务失败:"
        echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
        exit 1
    fi

    log_info "任务ID: $task_id"
    echo "$task_id"
}

# 轮询任务状态
poll_task() {
    local task_id="$1"
    local max_wait=3600
    local interval=10
    local elapsed=0

    log_info "等待转录完成..."

    while [ $elapsed -lt $max_wait ]; do
        local response
        response=$(curl -s --location --max-time 30 --request GET "https://dashscope.aliyuncs.com/api/v1/tasks/$task_id" \
            --header "Authorization: Bearer ${DASHSCOPE_API_KEY}" \
            --header "Content-Type: application/json")

        local status
        status=$(echo "$response" | jq -r '.output.task_status // empty')

        case "$status" in
            SUCCEEDED)
                log_info "转录完成!"
                local result_url
                result_url=$(echo "$response" | jq -r '.output.result.transcription_url // empty')
                if [ -z "$result_url" ]; then
                    log_error "无法获取结果URL"
                    exit 1
                fi
                echo "$result_url"
                return 0
                ;;
            FAILED)
                log_error "转录失败:"
                echo "$response" | jq '.output' >&2 2>/dev/null || echo "$response" >&2
                exit 1
                ;;
            PENDING|RUNNING)
                local minutes=$((elapsed / 60))
                local seconds=$((elapsed % 60))
                printf "\r${YELLOW}[等待]${NC} 状态: %s, 已等待: %02d:%02d" "$status" "$minutes" "$seconds" >&2
                sleep $interval
                elapsed=$((elapsed + interval))
                ;;
            *)
                log_error "未知状态: $status"
                echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
                exit 1
                ;;
        esac
    done

    log_error "超时: 转录任务未在 $max_wait 秒内完成"
    exit 1
}

# 下载结果
fetch_result() {
    local result_url="$1"
    local output_file="$2"

    log_info "下载转录结果..."
    curl -sL --max-time 60 "$result_url" > "$output_file"
    log_info "已保存到: $output_file"
}

# 加载 API key - 由文件顶部逻辑统一处理 (跨 agent 兼容)
load_api_key() {
    if [ -z "$DASHSCOPE_API_KEY" ]; then
        DASHSCOPE_API_KEY="${QWEN_API_KEY:-}"
        export DASHSCOPE_API_KEY
    fi
    if [ -z "$DASHSCOPE_API_KEY" ]; then
        log_error "请设置环境变量 DASHSCOPE_API_KEY (或 QWEN_API_KEY), 或写入以下任一文件:"
        log_error "  - ~/.config/xiaoyuzhou-transcribe/.env (推荐, 跨 agent)"
        log_error "  - ~/.hermes/.env (Hermes Agent 兼容)"
        exit 1
    fi
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        echo "用法: $0 <xiaoyuzhou_url_or_audio_url> [output_file]" >&2
        echo "示例: $0 'https://www.xiaoyuzhoufm.com/episode/xxxxx' /tmp/raw.json" >&2
        exit 1
    fi

    local input_url="$1"
    local output_file="${2:-/tmp/transcript_raw.json}"

    load_api_key
    check_deps

    # Step 1: 确定音频URL
    local audio_url
    if [[ "$input_url" == *"xiaoyuzhoufm.com"* ]]; then
        audio_url=$(extract_audio_url "$input_url")
    elif [[ "$input_url" == *".mp3"* ]] || [[ "$input_url" == *".m4a"* ]] || [[ "$input_url" == *".wav"* ]]; then
        audio_url="$input_url"
    else
        log_error "无法识别的URL格式 (需要 xiaoyuzhoufm.com 链接或 .mp3/.m4a/.wav 音频URL)"
        exit 1
    fi
    log_info "音频URL: $audio_url"

    # Step 2: 提交任务
    local task_id
    task_id=$(submit_task "$audio_url")

    # Step 3: 轮询结果
    echo "" >&2
    local result_url
    result_url=$(poll_task "$task_id")
    echo "" >&2

    # Step 4: 下载结果
    fetch_result "$result_url" "$output_file"

    # 输出纯文本预览
    log_info "转录文本预览:"
    PREVIEW=$(jq -r '.transcripts[0].text // .text' "$output_file" 2>/dev/null | head -c 500 || true)
    echo "$PREVIEW"
    echo "..."

    log_info "完成 ✓ 共 $(jq '.transcripts[0].sentences | length' "$output_file" 2>/dev/null || echo 0) 句"
}

main "$@"
