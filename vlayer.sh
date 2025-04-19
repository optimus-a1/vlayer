#!/bin/bash

# VLayer 一键安装与测试脚本 v17
# 特性：
# - Testnet 支持选择项目或全部执行
# - 支持多个 API Token 和 Private Key，生成 JSON 数组格式
# - 每个项目对每个账户轮流执行 Testnet，失败不会中断
# - 自动无限循环测试，每 10 分钟重复
# - 添加转账功能并处理错误重试

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info() {
    echo -e "${GREEN}[信息] $1${NC}"
}

echo_error() {
    echo -e "${RED}[错误] $1${NC}"
}

check_and_install() {
    if ! command -v $1 &> /dev/null; then
        echo_info "正在安装 $1..."
        eval "$2"
    else
        echo_info "$1 已安装，跳过"
    fi
}

install_dependencies() {
    echo_info "🔄 更新系统中..."
    apt update  # 只运行一次更新

    echo_info "📦 安装基础依赖..."
    check_and_install curl "apt install -y curl"
    check_and_install unzip "apt install -y unzip"
    check_and_install git "apt install -y git"
    check_and_install jq "apt install -y jq"
    check_and_install screen "apt install -y screen"  # 新增 screen
    check_and_install node "curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs"  # 新增 Node.js v20

    # Docker
    if ! command -v docker &> /dev/null; then
        echo_info "📦 安装 Docker..."
        apt install -y ca-certificates gnupg lsb-release
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo_info "✅ Docker 已安装，跳过"
    fi

    # 安装其他依赖（如 rust, foundry, bun 等）
    # （省略部分代码，已在你的原脚本中）
}

# 转账模块：执行转账并在失败时重试
transfer_eth() {
    sender_address=$1
    recipient_address=$2
    amount=$3
    retries=0
    max_retries=2
    success=false

    while [ $retries -le $max_retries ]; do
        echo_info "尝试转账 $amount ETH 从 $sender_address 到 $recipient_address (尝试次数：$((retries+1)))"
        # 假设使用 ethers.js 进行转账，命令或脚本的具体内容视乎你的设置
        if bun run batchTransferETH.js --sender "$sender_address" --recipient "$recipient_address" --amount "$amount"; then
            success=true
            echo_info "✅ 转账成功！"
            break
        else
            retries=$((retries + 1))
            echo_error "❌ 转账失败，正在重试..."
        fi
    done

    if [ "$success" = false ]; then
        echo_error "❌ 转账失败，地址 $sender_address 到 $recipient_address 的转账未成功。"
    fi
}

# 包括其他功能（如项目初始化、测试等）的代码（省略）

show_menu() {
    echo -e "${YELLOW}
========= VLayer 示例工具菜单 =========
1. 环境安装
2. 安装测试项目
3. 对项目进行Testnet 测试（单项测试）
4. 生成 api.json 和 key.json（支持多个账户）
5. 启动自动测试循环（每 10 分钟）
6. 执行转账（地址、金额）
0. 退出脚本
======================================
${NC}"
    read -rp "请输入选项编号：" choice
    case $choice in
        1) install_dependencies ;;
        2) show_project_menu ;;
        3) testnet_menu ;;
        4) generate_key_files ;;
        5) auto_test_loop ;;
        6)
            read -rp "请输入发送地址： " sender_address
            read -rp "请输入接收地址： " recipient_address
            read -rp "请输入转账金额： " amount
            transfer_eth "$sender_address" "$recipient_address" "$amount"
            ;;
        0) echo_info "退出脚本"; exit 0 ;;
        *) echo_error "无效选项，请重新运行脚本";;
    esac
}

# 启动菜单循环
while true; do
    show_menu
done
