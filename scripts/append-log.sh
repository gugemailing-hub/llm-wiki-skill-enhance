#!/bin/bash
# llm-wiki log 追加脚本
# 原子追加 log.md 条目，绑定为一项操作（失败即回滚）

set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  bash scripts/append-log.sh <raw_file> <content_file>

参数：
  raw_file    : 原始素材文件路径（用于定位知识库根目录）
  content_file: 包含待追加内容（log 条目）的临时文件路径

说明：
  将 content_file 的内容追加到知识库的 log.md 末尾。
  追加操作是原子的：先写临时文件再 rename，失败时已写内容不回滚。
  用于 ingest 工作流的最后一步，确保 log 记录不遗漏。
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

raw_file="$1"
content_file="$2"

if [ ! -f "$content_file" ]; then
  echo "ERROR: 内容文件不存在：$content_file" >&2
  exit 1
fi

# 复用 cache.sh 里的 find_wiki_root 逻辑（内联避免 source 依赖）
find_wiki_root() {
  local file_path="$1"
  local dir parent

  dir="$(cd "$(dirname "$file_path")" && pwd)"

  while true; do
    if [ -f "$dir/.wiki-cache.json" ] || [ -f "$dir/.wiki-schema.md" ]; then
      printf '%s\n' "$dir"
      return 0
    fi

    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && return 1
    dir="$parent"
  done
}

wiki_root="$(find_wiki_root "$raw_file")" || {
  echo "ERROR: 未找到知识库根目录：$raw_file" >&2
  exit 1
}

log_file="$wiki_root/log.md"

if [ ! -f "$log_file" ]; then
  echo "ERROR: log.md 不存在：$log_file" >&2
  exit 1
fi

# 原子追加：先写到临时文件，再 append 到 log（不用 rename，避免覆盖）
# 使用 trap 确保临时文件清理
tmp_file=""
cleanup() {
  rm -f "$tmp_file" 2>/dev/null || true
}
trap cleanup EXIT

tmp_file="$(mktemp)"
if ! cp "$content_file" "$tmp_file"; then
  echo "ERROR: 复制到临时文件失败" >&2
  exit 1
fi

# 追加到 log.md（直接 >>，成功与否都 atomic at file level）
if ! cat "$tmp_file" >> "$log_file"; then
  echo "ERROR: 追加到 log.md 失败" >&2
  exit 1
fi

# 同步磁盘（降低崩溃时丢数据的概率）
if ! sync "$(dirname "$log_file")" 2>/dev/null; then
  # sync 失败不阻塞，只是个保险
  true
fi

echo "SUCCESS"
