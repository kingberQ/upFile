#!/bin/bash

# 脚本功能：自动化安装 nockchain 挖矿环境并使用 PM2 + 包装脚本管理
# 作者：你的名字
# 日期：$(date +%Y-%m-%d)

set -e  # 遇到错误自动退出脚本

echo "=== 开始配置 nockchain 挖矿环境 ==="

# 配置 Linux 内核的内存过度提交行为
echo ">>> 设置 vm.overcommit_memory=1..."
sudo sysctl -w vm.overcommit_memory=1
echo ">>> vm.overcommit_memory 设置为 1 完成"

# 1. 安装 Rust（如果未安装）
if ! command -v rustc &> /dev/null; then
    echo ">>> 正在安装 Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    echo "Rust 安装完成！"
else
    echo "[跳过] Rust 已安装"
fi

# 2. 更新系统并安装依赖
echo ">>> 正在安装系统依赖..."
sudo apt update -y
sudo apt install -y clang llvm-dev libclang-dev make git curl
echo "依赖安装完成！"

# 3. 安装 Node.js 18.x 和 PM2
echo ">>> 正在安装 Node.js 18.x..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

echo ">>> 正在安装 PM2..."
npm install -g pm2
echo "PM2 安装完成！"

# 4. 克隆仓库（如果不存在）
if [ ! -d "nockchain" ]; then
    echo ">>> 正在克隆 nockchain 仓库..."
    git clone https://github.com/zorp-corp/nockchain.git
    cd nockchain
else
    echo "[跳过] 仓库已存在，进入目录"
    cd nockchain
    git pull  # 更新代码（可选）
fi

# 5. 复制环境文件
if [ ! -f ".env" ]; then
    echo ">>> 正在配置环境文件..."
    cp .env_example .env
    echo "环境文件已生成（请按需修改 .env）"
else
    echo "[跳过] .env 文件已存在"
fi

# 6. 安装 hoonc
if ! command -v hoonc &> /dev/null; then
    echo ">>> 正在编译 hoonc（耗时较长，请耐心等待）..."
    make install-hoonc
    export PATH="$HOME/.cargo/bin:$PATH"
    echo "hoonc 安装完成！"
else
    echo "[跳过] hoonc 已安装"
fi

# 7. 安装钱包
if ! command -v nockchain-wallet &> /dev/null; then
    echo ">>> 正在编译钱包（耗时较长，请耐心等待）..."
    make install-nockchain-wallet
    export PATH="$HOME/.cargo/bin:$PATH"
    echo "钱包安装完成！"
else
    echo "[跳过] 钱包已安装"
fi

# 8. 安装 nockchain
if ! command -v nockchain &> /dev/null; then
    echo ">>> 正在编译 nockchain（耗时最长，请耐心等待）..."
    make install-nockchain
    export PATH="$HOME/.cargo/bin:$PATH"
    echo "nockchain 安装完成！"
else
    echo "[跳过] nockchain 已安装"
fi

# 确保日志目录存在
mkdir -p /root/nockchain/logs

# 9. 获取当前服务器的 CPU 线程数并减去 2
CPU_THREADS=$(($(nproc) - 2))
echo ">>> 当前 CPU 线程数减去 2，设置 num-threads 为 $CPU_THREADS"

# 10. 下载 state.jam 文件
STATE_FILE="/root/nockchain/assets/state.jam"
if [ ! -f "$STATE_FILE" ]; then
    echo ">>> 文件 state.jam 不存在，开始下载..."
    mkdir -p /root/nockchain/assets
    curl -L -o "$STATE_FILE" https://zjq.cowtransfer.com/s/32e8a5e0ff2349
    echo ">>> 文件下载完成！"
else
    echo "[跳过] 文件 state.jam 已经存在"
fi

# 删除旧的日志文件
rm -f /root/nockchain/logs/mining.log

# 11. 创建包装脚本
echo ">>> 创建 nockchain 包装脚本..."
cat <<'EOL' > /root/nockchain/nockchain-wrapper.js
#!/usr/bin/env node
const { execSync, spawn } = require('child_process');
const path = require('path');

// 重启前清理函数
function cleanup() {
  try {
    console.log('[wrapper] 执行重启前清理...');
    execSync('rm -rf /root/nockchain/.socket');
    console.log('[wrapper] .socket 清理完成');
  } catch (err) {
    console.error('[wrapper] 清理失败:', err);
  }
}

// 捕获退出信号
const signals = ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGQUIT'];
signals.forEach(sig => {
  process.on(sig, () => {
    cleanup();
    process.exit(0);
  });
});

// 启动真实程序
console.log('[wrapper] 启动 nockchain 主程序...');
const args = process.argv.slice(2);
const child = spawn('/root/.cargo/bin/nockchain', args, {
  stdio: 'inherit',
  env: {
    ...process.env,
    PATH: process.env.PATH + ':/root/.cargo/bin'
  }
});

child.on('exit', (code) => {
  cleanup();
  process.exit(code || 0);
});

// 防止进程意外退出
process.stdin.resume();
EOL

# 设置包装脚本权限
chmod +x /root/nockchain/nockchain-wrapper.js

# 12. 执行挖矿命令并监控日志
echo ">>> 执行挖矿初始化..."
nockchain --mining-pubkey 37B27sAutZfFNJZcirEZvZwGBR1AKN8ofkzKUFQiywQJHvqkAkUn9L37ewtbohBeo8FEt9X5i4NyHHb6MUNnLjbS83DX9j1k61nrehLm54PjzebAFvMk3Hv8QDu6cN4NQMSi \
  --mine \
  --num-threads $CPU_THREADS \
  --state-jam /root/nockchain/assets/state.jam \
  >> /root/nockchain/logs/mining.log 2>&1

# 监控日志文件直到初始化完成
echo ">>> 正在监控日志以确认初始化完成..."
while ! grep -q "heard-block: Duplicate block" /root/nockchain/logs/mining.log; do
    sleep 5
    echo ">>> 正在等待初始化完成..."
done

# 停止当前挖矿程序
pkill -f '/root/.cargo/bin/nockchain' || true

# 13. 创建 PM2 配置文件
echo ">>> 创建 ecosystem.config.js 配置文件..."
cat <<EOL > /root/nockchain/ecosystem.config.js
module.exports = {
  apps: [{
    name: 'nockchain',
    script: '/root/nockchain/nockchain-wrapper.js',
    args: '--mining-pubkey 37B27sAutZfFNJZcirEZvZwGBR1AKN8ofkzKUFQiywQJHvqkAkUn9L37ewtbohBeo8FEt9X5i4NyHHb6MUNnLjbS83DX9j1k61nrehLm54PjzebAFvMk3Hv8QDu6cN4NQMSi --mine --num-threads $CPU_THREADS',
    restart_delay: 10000,
    log_file: '/root/nockchain/logs/mining.log',
    error_file: '/root/nockchain/logs/mining-error.log',
    out_file: '/root/nockchain/logs/mining-output.log',
    cwd: '/root/nockchain',
    env: {
      PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/.cargo/bin"
    }
  }]
};
EOL

# 14. 启动 PM2 管理挖矿进程
echo ">>> 使用 PM2 启动挖矿程序..."
pm2 start /root/nockchain/ecosystem.config.js

# 设置开机启动
echo ">>> 设置 PM2 开机启动..."
pm2 startup
pm2 save

echo "=== 所有步骤已完成！ ==="
echo ""
echo "管理命令:"
echo "  查看状态: pm2 list"
echo "  查看日志: pm2 logs nockchain"
echo "  停止: pm2 stop nockchain"
echo "  重启: pm2 restart nockchain"
echo ""
echo "注意: 通过包装脚本实现的自动清理功能会在每次进程退出时执行"