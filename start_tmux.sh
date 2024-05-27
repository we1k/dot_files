#!/bin/bash

# 检查是否提供了会话名称作为参数
if [ -z "$1" ]; then
    echo "Usage: $0 <session_name>"
    exit 1
fi

# 使用传入的参数作为会话名称
SESSION_NAME=$1

# 创建一个新的tmux会话
tmux new-session -d -s $SESSION_NAME


# 分割第一个窗口为上下两个窗格
tmux split-window -v -t $SESSION_NAME

# 再次分割每个窗格，这次为左右两个窗格
tmux split-window -h -t $SESSION_NAME:1.1

# 在第一个窗格中运行gpustat
# tmux send-keys -t $SESSION_NAME:1.1 'gpustat -i 1' C-m
tmux send-keys -t $SESSION_NAME:1.1 'nvitop -m auto' C-m


# 在第二个窗格中运行htop
tmux send-keys -t $SESSION_NAME:1.2 'htop' C-m

# 选择合适的布局（可选）
tmux select-layout -t $SESSION_NAME tiled

# 切换回第一个窗格
tmux select-window -t $SESSION_NAME:1
tmux select-pane -t 1

# 附加到会话
tmux attach -t $SESSION_NAME
