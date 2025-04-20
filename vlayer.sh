#!/bin/bash

# VLayer 一键安装与测试脚本 v16（新增批量 ETH 转账模块）
# 特性：
# - Testnet 支持选择项目或全部执行
# - 支持多个 API Token 和 Private Key，生成 JSON 数组格式
# - 每个项目对每个账户轮流执行 Testnet，失败不会中断
# - 自动无限循环测试，每 10 分钟重复
# - 批量 ETH 转账：固定金额，逐行输入地址，失败重试 2 次，显示最终失败地址

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
const { ethers } = require("ethers");
const fs = require("fs");
const readline = require("readline");

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

async function getFixedAmount() {
    return new Promise((resolve) => {
        rl.question("请输入固定的转账金额（ETH，例如 0.01）：", (amount) => {
            try {
                const amountWei = ethers.parseEther(amount.trim());
                if (amountWei <= 0) throw new Error("金额必须大于 0");
                resolve(amountWei);
            } catch (error) {
                console.error(\`无效金额：\${amount}，请重新输入\`);
                getFixedAmount().then(resolve);
            }
        });
    });
}

async function getAddresses() {
    const addresses = [];
    console.log("请输入目标地址，每行一个地址（输入空行结束）");
    console.log("示例：0x1234567890abcdef1234567890abcdef12345678");

    return new Promise((resolve) => {
        rl.on("line", (line) => {
            line = line.trim();
            if (line === "") {
                rl.close();
                resolve(addresses);
                return;
            }
            if (!ethers.isAddress(line)) {
                console.error(\`无效地址：\${line}，请继续输入下一个地址\`);
                return;
            }
            addresses.push(line);
        });
    });
}

async function tryTransfer(wallet, address, amount, maxRetries = 2) {
    let attempt = 0;
    while (attempt <= maxRetries) {
        try {
            const feeData = await wallet.provider.getFeeData();
            const tx = await wallet.sendTransaction({
                to: address,
                value: amount,
                gasLimit: 21000,
                maxFeePerGas: feeData.maxFeePerGas || ethers.parseUnits("2", "gwei"),
                maxPriorityFeePerGas: feeData.maxPriorityFeePerGas || ethers.parseUnits("1", "gwei")
            });
            console.log(\`交易哈希（尝试 \${attempt + 1}）：\${tx.hash}\`);
            await tx.wait();
            console.log(\`转账成功：\${address}\`);
            return true;
        } catch (error) {
            attempt++;
            console.error(\`转账失败（尝试 \${attempt}/\${maxRetries + 1}）：\${address}，错误：\${error.message}\`);
            if (attempt > maxRetries) {
                return false;
            }
            await new Promise(resolve => setTimeout(resolve, 2000));
        }
    }
    return false;
}

async function main() {
    const provider = new ethers.JsonRpcProvider("https://sepolia.optimism.io");
    let privateKeys;
    try {
        privateKeys = JSON.parse(fs.readFileSync("../../key.json"));
        if (!Array.isArray(privateKeys) || privateKeys.length === 0) {
            throw new Error("key.json 为空或格式不正确");
        }
    } catch (error) {
        console.error("错误：无法读取 vlayer/key.json 或文件格式错误");
        process.exit(1);
    }

    const privateKey = privateKeys[0];
    let wallet;
    try {
        wallet = new ethers.Wallet(privateKey, provider);
    } catch (error) {
        console.error(\`无效私钥：\${privateKey.slice(0, 10)}...\`);
        process.exit(1);
    }

    console.log(\`\\n使用账户：\${wallet.address}\`);

    const fixedAmount = await getFixedAmount();
    console.log(\`固定转账金额：\${ethers.formatEther(fixedAmount)} ETH\`);

    const addresses = await getAddresses();
    if (addresses.length === 0) {
        console.error("错误：未输入任何有效地址");
        process.exit(1);
    }

    const balance = await provider.getBalance(wallet.address);
    const totalAmount = fixedAmount * BigInt(addresses.length);
    if (balance < totalAmount) {
        console.error(\`账户余额不足：\${ethers.formatEther(balance)} ETH，需 \${ethers.formatEther(totalAmount)} ETH\`);
        process.exit(1);
    }

    console.log(\`\\n开始向 \${addresses.length} 个地址转账...\`);
    const failedAddresses = [];
    for (const address of addresses) {
        console.log(\`\\n向 \${address} 转账 \${ethers.formatEther(fixedAmount)} ETH\`);
        const success = await tryTransfer(wallet, address, fixedAmount);
        if (!success) {
            failedAddresses.push(address);
        }
    }

    if (failedAddresses.length > 0) {
        console.log("\\n以下地址转账失败（经过 3 次尝试）：");
        failedAddresses.forEach(address => console.log(\`- \${address}\`));
    } else {
        console.log("\\n所有转账均成功！");
    }

    console.log("\\n所有转账处理完成");
    process.exit(0);
}

main().catch((error) => {
    console.error("脚本执行错误：", error.message);
    process.exit(1);
});
EOF
    bun run batchTransferETH.js
    cd ../../../
    echo_info "✅ 批量转账完成"
}

show_menu() {
    echo -e "${YELLOW}
========= VLayer 示例工具菜单 =========
1. 环境安装
2. 安装测试项目
3. 对项目进行Testnet 测试（单项测试）
4. 生成 api.json 和 key.json（支持多个账户）
5. 启动自动测试循环（每 10 分钟）
6. 批量 ETH 转账（使用 key.json 第一个私钥）
0. 退出脚本
=======================================
${NC}"
    read -rp "请输入选项编号：" choice
    case $choice in
        1) install_dependencies ;;
        2) show_project_menu ;;
        3) testnet_menu ;;
        4) generate_key_files ;;
        5) auto_test_loop ;;
        6) batch_transfer_eth ;;
        0) echo_info "退出脚本"; exit 0 ;;
        *) echo_error "无效选项，请重新运行脚本";;
    esac
}

echo_info "加载 bash 环境..."
source ~/.bashrc || source /root/.bashrc
export PATH="$HOME/.bun/bin:$HOME/.vlayer/bin:$HOME/.foundry/bin:$PATH"

while true; do
    show_menu
done
