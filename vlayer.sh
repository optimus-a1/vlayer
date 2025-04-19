#!/bin/bash

# VLayer 一键安装与测试脚本 v16（新增批量 ETH 转账模块）
# 特性：
# - Testnet 支持选择项目或全部执行
# - 支持多个 API Token 和 Private Key，生成 JSON 数组格式
# - 每个项目对每个账户轮流执行 Testnet，失败不会中断
# - 自动无限循环测试，每 10 分钟重复
# - 新增批量 ETH 转账（固定金额，逐行输入地址，重试 2 次，显示失败地址）

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
    check_and_install screen "apt install -y screen"
    check_and_install node "curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs"

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

    # Rust
    if ! command -v rustup &> /dev/null; then
        echo_info "🦀 安装 Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
    source $HOME/.cargo/env
    rustup update

    # Foundry
    if ! command -v foundryup &> /dev/null; then
        echo_info "🔨 安装 Foundry..."
        curl -L https://foundry.paradigm.xyz | bash
    fi
    export PATH="$HOME/.foundry/bin:$PATH"
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
    foundryup

    # Bun
    if ! command -v bun &> /dev/null; then
        echo_info "⚡ 安装 Bun..."
        curl -fsSL https://bun.sh/install | bash
    fi
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.bashrc
    echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.bashrc

    # VLayer CLI
    if ! command -v vlayerup &> /dev/null; then
        echo_info "🌐 安装 VLayer CLI..."
        curl -SL https://install.vlayer.xyz | bash
    fi
    export PATH="$HOME/.vlayer/bin:$PATH"
    echo 'export PATH="$HOME/.vlayer/bin:$PATH"' >> ~/.bashrc
    vlayerup

    echo_info "所有依赖安装完成 ✅"
}

init_project_only() {
    name=$1
    template=$2
    mkdir -p vlayer
    cd vlayer
    if [ -d "$name" ]; then
        echo_info "⚠️ 项目 $name 已存在，正在跳过初始化"
        cd ..
        return
    fi
    echo_info "初始化项目：$name（模板：$template）"
    vlayer init "$name" --template "$template"
    cd "$name"
    forge build
    cd vlayer
    bun install
    cd ../../../
    echo_info "✅ $name 安装完成（未运行 prove:dev）"
}

generate_key_files() {
    mkdir -p vlayer
    echo_info "请输入多个 VLayer API Token 和 Private Key（输入空行以结束）"
    tokens=()
    private_keys=()
    index=1

    while true; do
        echo_info "账户 $index"
        read -rp "API Token: " token
        if [ -z "$token" ]; then
            break
        fi
        read -rp "Private Key: " private_key
        if [ -z "$private_key" ]; then
            echo_error "Private Key 不能为空，跳过此账户"
            continue
        fi
        tokens+=("\"$token\"")
        private_keys+=("\"$private_key\"")
        ((index++))
    done

    if [ ${#tokens[@]} -eq 0 ]; then
        echo_error "未输入任何有效账户，跳过生成"
        return
    fi

    # 生成 JSON 数组格式的 api.json 和 key.json
    api_json="[$(
        IFS=,
        echo "${tokens[*]}"
    )]"
    key_json="[$(
        IFS=,
        echo "${private_keys[*]}"
    )]"

    echo "$api_json" > vlayer/api.json
    echo "$key_json" > vlayer/key.json
    echo_info "已生成 vlayer/api.json 和 vlayer/key.json（JSON 数组格式）"
}

test_with_testnet() {
    project_dir=$1
    if [ ! -d "vlayer/$project_dir/vlayer" ]; then
        echo_error "❌ 项目目录 vlayer/$project_dir/vlayer 不存在，请先安装"
        return 1
    fi
    echo_info "准备 Testnet 测试：$project_dir"
    cd "vlayer/$project_dir/vlayer"

    if [[ -f ../../api.json && -f ../../key.json ]]; then
        # 读取 JSON 数组
        api_tokens=($(cat ../../api.json | jq -r '.[]'))
        private_keys=($(cat ../../key.json | jq -r '.[]'))

        if [ ${#api_tokens[@]} -ne ${#private_keys[@]} ]; then
            echo_error "❌ api.json 和 key.json 的账户数量不匹配"
            cd ../../../
            return 1
        fi

        for i in "${!api_tokens[@]}"; do
            echo_info "正在为账户 $((i+1)) 测试项目 $project_dir"
            API_TOKEN="${api_tokens[$i]}"
            PRIVATE_KEY="${private_keys[$i]}"

            echo_info "生成 .env.testnet.local 文件（账户 $((i+1))）"
            cat <<EOF > .env.testnet.local
VLAYER_API_TOKEN=$API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$PRIVATE_KEY
CHAIN_NAME=optimismSepolia
JSON_RPC_URL=https://sepolia.optimism.io
EOF

            echo_info "开始运行 Testnet 证明（账户 $((i+1))）..."
            if ! bun run prove:testnet; then
                echo_error "❌ 账户 $((i+1)) 测试失败，继续下一个账户..."
            else
                echo_info "✅ 账户 $((i+1)) 测试成功"
            fi
        done
    else
        echo_error "❌ 缺少 api.json 或 key.json 文件"
        cd ../../../
        return 1
    fi
    cd ../../../
    return 0
}

testnet_menu() {
    echo -e "${YELLOW}
========= Testnet 测试菜单 =========
1. 测试 email_proof_project
2. 测试 teleport_project
3. 测试 time_travel_project
4. 测试 my_first_project
5. 所有项目全部测试
0. 返回主菜单
===================================
${NC}"
    read -rp "请选择要运行的编号：" test_choice
    case $test_choice in
        1) test_with_testnet "email_proof_project" ;;
        2) test_with_testnet "teleport_project" ;;
        3) test_with_testnet "time_travel_project" ;;
        4) test_with_testnet "my_first_project" ;;
        5)
           for project in "email_proof_project" "teleport_project" "time_travel_project" "my_first_project"; do
               echo_info "开始测试项目：$project"
               if ! test_with_testnet "$project"; then
                   echo_error "❌ $project 测试失败，继续下一个项目..."
               fi
           done
           ;;
        0) return ;;
        *) echo_error "无效选择，请重试。" ;;
    esac
}

auto_test_loop() {
    echo_info "启动自动测试循环（每 10 分钟运行一次）"
    while true; do
        echo_info "开始新一轮测试：$(date)"
        for project in "email_proof_project" "teleport_project" "time_travel_project" "my_first_project"; do
            echo_info "自动测试项目：$project"
            if ! test_with_testnet "$project"; then
                echo_error "❌ $project 测试失败，继续下一个项目..."
            fi
        done
        echo_info "本轮测试完成，等待 10 分钟后继续..."
        sleep 600
    done
}

show_project_menu() {
    echo -e "${YELLOW}
========= 项目安装菜单 =========
a. my_first_project (simple)
b. email_proof_project
c. teleport_project
d. time_travel_project
e. 全部安装
0. 返回主菜单
================================
${NC}"
    read -rp "请选择要安装的项目编号：" project_choice
    case $project_choice in
        a) init_project_only "my_first_project" "simple" ;;
        b) init_project_only "email_proof_project" "simple-email-proof" ;;
        c) init_project_only "teleport_project" "simple-teleport" ;;
        d) init_project_only "time_travel_project" "simple-time-travel" ;;
        e)
           init_project_only "my_first_project" "simple"
           init_project_only "email_proof_project" "simple-email-proof"
           init_project_only "teleport_project" "simple-teleport"
           init_project_only "time_travel_project" "simple-time-travel"
           ;;
        0) return ;;
        *) echo_error "无效选择，请重试。" ;;
    esac
}

batch_transfer_eth() {
    echo_info "执行批量 ETH 转账（使用 key.json 中的第一个私钥）..."
    mkdir -p vlayer/multisender/scripts
    cd vlayer/multisender/scripts
    if [ ! -f "package.json" ]; then
        bun init
    fi
    bun add ethers
    cat <<EOF > batchTransferETH.js
const
