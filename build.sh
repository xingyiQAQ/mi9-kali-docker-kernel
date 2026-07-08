#!/bin/bash

# 开启绝对保护，遇错即停
set -e

# ==================== 配置区域 ====================
KERNEL_REPO="https://github.com/crdroidandroid/android_kernel_xiaomi_sm8150"
KERNEL_BRANCH="13.0"                           # crDroid 9.x 对应的安卓 13 分支
DEFCONFIG_FILE="vendor/sm8150-perf_defconfig"  # 高通通用配置
TOOLCHAIN_REPO="https://github.com/kdrag0n/proton-clang"
# ==================================================

export ARCH=arm64
export SUBARCH=arm64

echo "=== 1. 克隆内核源码与工具链 ==="
rm -rf kernel toolchain out AnyKernel3
git clone --depth=1 -b $KERNEL_BRANCH $KERNEL_REPO kernel
git clone --depth=1 $TOOLCHAIN_REPO toolchain

export PATH="$(pwd)/toolchain/bin:$PATH"

echo "=== 2. 注入 KernelSU-Next (Legacy 模式) ==="
cd kernel
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy
cd ..

echo "=== 3. 跨路径精准注入桩函数与高通总线净化 ==="

# 【安全打桩】精准注入 KSU 遗留的硬编码强符号，确保核心层编译通过
cat << 'EOF' >> kernel/kernel/sys.c

/* ==================== 彻底火化老旧 KSU 硬编码符号 ==================== */
int ksu_handle_faccessat(void *dfd, const void *filename, void *mode, void *flags) { return 0; }
int ksu_handle_execve(void *fd, void *filename, void *argv, void *envp) { return 0; }
int ksu_handle_vfs_read(void *file, void *buf, void *count, void *pos) { return 0; }
int ksu_input_hook(unsigned int type, unsigned int code, int value) { return 0; }
int ksu_handle_setuid(void *uid) { return 0; }
int ksu_handle_setgid(void *gid) { return 0; }
EOF

# 【终极修复】恢复 Makefile，对 msm_bus_dbg_rpmh.c 进行不破坏语法的“局部符号伪装”
# 将引发错误的目标 Tracepoint 替换为本地空桩函数，彻底解决未定义和连带符号丢失问题
TARGET_SRC="kernel/drivers/soc/qcom/msm_bus/msm_bus_dbg_rpmh.c"
if [ -f "$TARGET_SRC" ]; then
    echo "正在对高通总线调试源码实施局部符号净化..."
    # 1. 在文件末尾追加一个安全的、接受任意参数的空函数
    cat << 'EOF' >> "$TARGET_SRC"

/* 桩函数：无损替代无法解析的高通总线 Tracepoint */
void dummy_trace_bus_update_request(const char *name, unsigned int ts, unsigned long long bus_cl) {
    (void)name; (void)ts; (void)bus_cl;
}
EOF
    # 2. 将代码中的原有调用精准重定向到我们的桩函数，规避复杂的头文件地狱
    sed -i 's/trace_bus_update_request/dummy_trace_bus_update_request/g' "$TARGET_SRC"
fi

# 隔离第三方维护者可能在常规驱动中硬编码的 CONFIG_KSU 宏控制（排除我们新注入的 kernelsu 驱动）
find kernel/ -type f \( -name "*.c" -o -name "*.h" -o -name "Makefile" -o -name "Kconfig" \) ! -path "kernel/drivers/kernelsu/*" -exec sed -i 's/CONFIG_KSU/CONFIG_KSU_MANUAL_HOOK/g' {} +

echo "=== 4. 注入 Docker + LXC + NetHunter 核心内核配置 ==="
cat << 'EOF' >> kernel/arch/arm64/configs/$DEFCONFIG_FILE

# --- KERNELSU NEXT CONFIG ---
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_KSU=y
CONFIG_KSU_KPROBE_HOOKS=y

# --- DOCKER & LXC CORE CONFIG ---
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_HUGETLB=y
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_DEVPTS_MULTIPLE_INSTANCES=y
CONFIG_OVERLAY_FS=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_LOOP_MIN_COUNT=8

# --- DOCKER NETWORK EXTRA INFRASTRUCTURE ---
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y
CONFIG_NETFILTER_XT_MATCH_STATE=y

# --- NETWORKING & BRIDGING ---
CONFIG_NETFILTER=y
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_VETH=y
CONFIG_NETFILTER_XT_MATCH_COMMENT=y
CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_TARGET_REJECT=y
CONFIG_IP_NF_MANGLE=y
CONFIG_IP_NF_NAT=y

# --- KALI NETHUNTER CONFIG ---
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_F_HID=y
CONFIG_USB_G_ANDROID=y
CONFIG_WIRELESS=y
CONFIG_CFG80211=y
CONFIG_MAC80211=y
CONFIG_BT=y
CONFIG_BT_RFCOMM=y
CONFIG_BT_HCIBTUSB=y
EOF

echo "=== 5. 开始整洁编译 ==="
cd kernel

MAKE_FLAGS=(
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    CC=clang \
    AR=llvm-ar \
    NM=llvm-nm \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    STRIP=llvm-strip \
    LLVM=1 \
    LLVM_IAS=1
)

make clean && make mrproper
make O=out $DEFCONFIG_FILE
make O=out "${MAKE_FLAGS[@]}" -j$(nproc)

echo "=== 6. 打包 AnyKernel3 卡刷包 ==="
cd ..
git clone https://github.com/osm0sis/AnyKernel3.git
sed -i 's/device.name1=/device.name1=cepheus/g' AnyKernel3/anykernel.sh

if [ -f "kernel/out/arch/arm64/boot/Image.gz-dtb" ]; then
    cp kernel/out/arch/arm64/boot/Image.gz-dtb AnyKernel3/
elif [ -f "kernel/out/arch/arm64/boot/Image.gz" ]; then
    cp kernel/out/arch/arm64/boot/Image.gz AnyKernel3/
else
    echo "❌ 错误：未找到编译生成的内核文件！"
    exit 1
fi

cd AnyKernel3
zip -r9 ../docker-ksu-nethunter-kernel-cepheus.zip *
echo "🎉 完美通关！高通内核底层连环符号彻底解开，AnyKernel3 打包圆满成功！"
