#!/bin/bash
# v_ai_avatar 代码同步脚本
# 支持本地和服务器之间的双向同步，版本控制和冲突处理

set -e

# 配置
REMOTE_HOST="dev_lzw"
REMOTE_PATH="v_ai_avatar"
LOCAL_PATH="/Users/bytedance/Documents/project/v_ai_avatar"
BACKUP_DIR="$LOCAL_PATH/.sync_backups"
EXCLUDE_FILE="$LOCAL_PATH/.sync_exclude"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}


# 获取文件修改时间戳
get_file_timestamp() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            stat -f "%m" "$file_path" 2>/dev/null || echo "0"
        else
            stat -c "%Y" "$file_path" 2>/dev/null || echo "0"
        fi
    else
        echo "0"
    fi
}

# 获取远程文件修改时间戳
get_remote_file_timestamp() {
    local remote_file="$1"
    ssh "$REMOTE_HOST" "cd $REMOTE_PATH && stat -c '%Y' '$remote_file' 2>/dev/null || echo '0'"
}

# 备份当前状态
backup_current_state() {
    local backup_name="backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    log_info "创建备份: $backup_name"
    mkdir -p "$backup_path"
    
    # 备份关键文件
    rsync -av --exclude-from="$EXCLUDE_FILE" "$LOCAL_PATH/" "$backup_path/local/" > /dev/null
    
    # 备份远程文件
    mkdir -p "$backup_path/remote"
    ssh "$REMOTE_HOST" "cd $REMOTE_PATH && tar czf - --exclude-from=<(echo '__pycache__'; echo '*.pyc'; echo '*.log') ." | tar xzf - -C "$backup_path/remote/" 2>/dev/null || true
    
    echo "$backup_name" > "$BACKUP_DIR/latest_backup"
    log_info "备份完成: $backup_path"
}

# 推送到服务器 (本地 -> 服务器)
push_to_server() {
    local files=("$@")
    
    log_info "推送文件到服务器..."
    
    if [ ${#files[@]} -eq 0 ]; then
        # 全量同步
        log_info "执行全量推送"
        rsync -avz --delete --exclude-from="$EXCLUDE_FILE" \
            "$LOCAL_PATH/" "$REMOTE_HOST:$REMOTE_PATH/"
    else
        # 增量同步指定文件
        for file in "${files[@]}"; do
            if [ -f "$LOCAL_PATH/$file" ]; then
                log_info "推送文件: $file"
                # 确保远程目录存在
                ssh "$REMOTE_HOST" "mkdir -p $REMOTE_PATH/$(dirname "$file")"
                scp "$LOCAL_PATH/$file" "$REMOTE_HOST:$REMOTE_PATH/$file"
            else
                log_warn "文件不存在: $file"
            fi
        done
    fi
    
    log_info "推送完成"
}

# 从服务器拉取 (服务器 -> 本地)
pull_from_server() {
    local files=("$@")
    
    log_info "从服务器拉取文件..."
    
    if [ ${#files[@]} -eq 0 ]; then
        # 全量同步
        log_info "执行全量拉取"
        rsync -avz --delete --exclude-from="$EXCLUDE_FILE" \
            "$REMOTE_HOST:$REMOTE_PATH/" "$LOCAL_PATH/"
    else
        # 增量同步指定文件
        for file in "${files[@]}"; do
            log_info "拉取文件: $file"
            # 确保本地目录存在
            mkdir -p "$LOCAL_PATH/$(dirname "$file")"
            scp "$REMOTE_HOST:$REMOTE_PATH/$file" "$LOCAL_PATH/$file" 2>/dev/null || log_warn "拉取失败: $file"
        done
    fi
    
    log_info "拉取完成"
}

# 智能同步 - 检测冲突并处理
smart_sync() {
    local sync_files=("$@")
    
    log_info "开始智能同步..."
    create_backup_dir
    backup_current_state
    
    if [ ${#sync_files[@]} -eq 0 ]; then
        # 全量智能同步
        log_info "执行全量智能同步"
        
        # 首先获取服务器上的文件列表
        local server_files=$(ssh "$REMOTE_HOST" "cd $REMOTE_PATH && find . -name '*.py' -type f | grep -v __pycache__ | sed 's|^\./||'")
        
        for file in $server_files; do
            local local_time=$(get_file_timestamp "$LOCAL_PATH/$file")
            local remote_time=$(get_remote_file_timestamp "$file")
            
            if [ "$local_time" -gt "$remote_time" ]; then
                log_debug "本地较新: $file (本地:$local_time vs 远程:$remote_time)"
                push_to_server "$file"
            elif [ "$remote_time" -gt "$local_time" ]; then
                log_debug "服务器较新: $file (本地:$local_time vs 远程:$remote_time)"
                pull_from_server "$file"
            fi
        done
        
        # 检查本地独有文件
        find "$LOCAL_PATH" -name "*.py" -type f | while read local_file; do
            file=${local_file#$LOCAL_PATH/}
            if ! ssh "$REMOTE_HOST" "[ -f $REMOTE_PATH/$file ]" 2>/dev/null; then
                log_debug "本地独有文件: $file"
                push_to_server "$file"
            fi
        done
    else
        # 指定文件智能同步
        for file in "${sync_files[@]}"; do
            local local_time=$(get_file_timestamp "$LOCAL_PATH/$file")
            local remote_time=$(get_remote_file_timestamp "$file")
            
            if [ "$local_time" -gt "$remote_time" ]; then
                log_info "推送较新的本地文件: $file"
                push_to_server "$file"
            elif [ "$remote_time" -gt "$local_time" ]; then
                log_info "拉取较新的服务器文件: $file"
                pull_from_server "$file"
            else
                log_info "文件已同步: $file"
            fi
        done
    fi
    
    log_info "智能同步完成"
}

# 检查连接
check_connection() {
    log_info "检查服务器连接..."
    if ssh "$REMOTE_HOST" "echo 'Connection OK'" >/dev/null 2>&1; then
        log_info "服务器连接正常"
        return 0
    else
        log_error "无法连接到服务器: $REMOTE_HOST"
        return 1
    fi
}

# 显示状态
show_status() {
    log_info "同步状态检查..."
    
    # 检查最近修改的文件
    log_info "本地最近修改的Python文件 (最近10个):"
    find "$LOCAL_PATH" -name "*.py" -type f -mtime -1 | head -10 | while read file; do
        rel_path=${file#$LOCAL_PATH/}
        local_time=$(get_file_timestamp "$file")
        remote_time=$(get_remote_file_timestamp "$rel_path")
        
        if [ "$local_time" -gt "$remote_time" ]; then
            echo "  📝 $rel_path (本地较新)"
        elif [ "$remote_time" -gt "$local_time" ]; then
            echo "  📥 $rel_path (服务器较新)"
        else
            echo "  ✅ $rel_path (已同步)"
        fi
    done
}

# 恢复备份
restore_backup() {
    local backup_name="$1"
    
    if [ -z "$backup_name" ]; then
        if [ -f "$BACKUP_DIR/latest_backup" ]; then
            backup_name=$(cat "$BACKUP_DIR/latest_backup")
        else
            log_error "没有可用的备份"
            return 1
        fi
    fi
    
    local backup_path="$BACKUP_DIR/$backup_name"
    
    if [ ! -d "$backup_path" ]; then
        log_error "备份不存在: $backup_name"
        return 1
    fi
    
    log_warn "恢复备份: $backup_name"
    read -p "确认恢复备份? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 恢复本地
        rsync -av --delete "$backup_path/local/" "$LOCAL_PATH/"
        
        # 恢复远程
        tar czf - -C "$backup_path/remote" . | ssh "$REMOTE_HOST" "cd $REMOTE_PATH && tar xzf -"
        
        log_info "备份恢复完成"
    else
        log_info "取消恢复"
    fi
}

# Git工作区管理
git_stash_changes() {
    local stash_name="sync_stash_$(date +%Y%m%d_%H%M%S)"
    
    if git diff --quiet && git diff --cached --quiet; then
        log_debug "没有需要stash的修改"
        return 0
    fi
    
    log_info "暂存当前修改: $stash_name"
    git stash push -m "$stash_name" --include-untracked 2>/dev/null || true
    echo "$stash_name" > "$LOCAL_PATH/.last_stash"
}

git_restore_stash() {
    if [ -f "$LOCAL_PATH/.last_stash" ]; then
        local last_stash=$(cat "$LOCAL_PATH/.last_stash")
        log_info "恢复暂存的修改: $last_stash"
        git stash pop 2>/dev/null || log_warn "无法恢复stash"
        rm -f "$LOCAL_PATH/.last_stash"
    fi
}

# 开发模式管理
start_dev_session() {
    log_info "开始开发会话..."
    
    # 创建开发分支标记
    echo "$(date +%Y%m%d_%H%M%S)" > "$LOCAL_PATH/.dev_session"
    
    # stash当前修改
    git_stash_changes
    
    log_info "开发会话已启动，所有修改将在会话结束时统一提交"
}

end_dev_session() {
    if [ ! -f "$LOCAL_PATH/.dev_session" ]; then
        log_warn "没有活跃的开发会话"
        return 1
    fi
    
    local session_id=$(cat "$LOCAL_PATH/.dev_session")
    log_info "结束开发会话: $session_id"
    
    # 恢复stash的修改
    git_restore_stash
    
    # 显示当前修改状态
    echo ""
    log_info "当前修改状态:"
    git status --short
    
    echo ""
    read -p "是否要将所有修改合并为一个commit? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 添加所有修改
        git add -A
        
        # 提示输入commit信息
        echo "请输入commit信息 (默认: 开发会话 $session_id 的修改):"
        read -r commit_msg
        
        if [ -z "$commit_msg" ]; then
            commit_msg="开发会话 $session_id 的修改"
        fi
        
        # 提交
        git commit -m "$commit_msg"
        log_info "已创建统一commit: $commit_msg"
    else
        log_info "修改保留在工作区，可手动管理"
    fi
    
    # 清理会话文件
    rm -f "$LOCAL_PATH/.dev_session"
    rm -f "$LOCAL_PATH/.last_stash"
}

# 工作区状态检查
check_dev_session() {
    if [ -f "$LOCAL_PATH/.dev_session" ]; then
        local session_id=$(cat "$LOCAL_PATH/.dev_session")
        log_info "当前开发会话: $session_id"
        return 0
    else
        return 1
    fi
}

# 主函数
main() {
    
    case "$1" in
        "push")
            check_connection || exit 1
            shift
            push_to_server "$@"
            ;;
        "pull")
            check_connection || exit 1
            shift
            pull_from_server "$@"
            ;;
        "sync")
            check_connection || exit 1
            shift
            smart_sync "$@"
            ;;
        "status")
            check_connection || exit 1
            show_status
            ;;
        "backup")
            backup_current_state
            ;;
        "restore")
            restore_backup "$2"
            ;;
        "start-dev")
            start_dev_session
            ;;
        "end-dev")
            end_dev_session
            ;;
        "dev-status")
            if check_dev_session; then
                git status --short
            else
                log_info "没有活跃的开发会话"
                git status --short
            fi
            ;;
        "watch")
            # 监控模式 - 自动同步修改的文件
            log_info "启动文件监控模式 (Ctrl+C 退出)"
            check_connection || exit 1
            
            # 使用fswatch监控文件变化
            if command -v fswatch >/dev/null 2>&1; then
                fswatch -o "$LOCAL_PATH" --exclude="$EXCLUDE_FILE" | while read event; do
                    log_info "检测到文件变化，执行智能同步..."
                    smart_sync
                    sleep 2  # 防止频繁同步
                done
            else
                log_warn "未安装fswatch，使用轮询模式"
                while true; do
                    smart_sync
                    sleep 10
                done
            fi
            ;;
        *)
            echo "v_ai_avatar 代码同步工具"
            echo ""
            echo "用法: $0 <command> [options]"
            echo ""
            echo "命令:"
            echo "  push [files...]     推送文件到服务器 (本地 -> 服务器)"
            echo "  pull [files...]     从服务器拉取文件 (服务器 -> 本地)"
            echo "  sync [files...]     智能双向同步 (基于修改时间)"
            echo "  status              显示同步状态"
            echo "  backup              创建当前状态备份"
            echo "  restore [name]      恢复指定备份 (默认最新)"
            echo "  watch               监控文件变化并自动同步"
            echo ""
            echo "示例:"
            echo "  $0 start-dev                     # 开始开发会话"
            echo "  $0 push local_chat.py           # 推送单个文件"
            echo "  $0 sync                          # 智能全量同步"
            echo "  $0 dev-status                    # 查看开发状态"
            echo "  $0 end-dev                       # 结束并统一提交"
            echo ""
            ;;
    esac
}

# 执行主函数
main "$@"