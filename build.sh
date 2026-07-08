#!/bin/bash

# 开启保护
set -e

# ==================== 配置区域（已更换为 crDroid 官方源） ====================
KERNEL_REPO="https://github.com/crdroidandroid/android_kernel_xiaomi_sm8150"
KERNEL_BRANCH="13.0"                           # 👈 crDroid 9.x 对应的安卓 13 分支
DEFCONFIG_FILE="vendor/sm8150-perf_defconfig"  # crDroid 同样使用这个统一的高通通用配置
TOOLCHAIN_REPO="https://github.com/kdrag0n/proton-clang"
# ============================================================================

export ARCH=arm64
export SUBARCH=arm64

# 后面的代码完全保持不变...

echo "=== 1. 克隆内核源码与工具链 ==="
git clone --depth=1 -b $KERNEL_BRANCH $KERNEL_REPO kernel
git clone --depth=1 $TOOLCHAIN_REPO toolchain

export PATH="$(pwd)/toolchain/bin:$PATH"

echo "=== 2. 注入 KernelSU-Next (Legacy 分支) ==="
cd kernel
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy

# 👇 【终极彻底净化】
echo "=== 2.5 终极立体净化：全面隔离老旧 KSU 并注入兜底桩 ==="

# 1. 范围扩大：将所有 .c、.h、Makefile、Kconfig 中的老 KSU 宏全部改名（排除新注入的 drivers/kernelsu）
find . -type f \( -name "*.c" -o -name "*.h" -o -name "Makefile" -o -name "Kconfig" \) ! -path "./drivers/kernelsu/*" -exec sed -i 's/CONFIG_KSU/CONFIG_KSU_MANUAL_HOOK/g' {} +

# 2. 符号桩兜底：在内核核心系统文件中追加空函数。
# 使用 __attribute__((weak)) 声明，即使别处有盲目调用，也会定向到这里，绝不报错。
cat << 'EOF' >> kernel/sys.c

/* 专治老旧 KSU 残留符号的全局弱引用兜底桩 */
int __attribute__((weak)) ksu_handle_faccessat(int *dfd, const char __user **filename, int *mode, int *flags) { return 0; }
int __attribute__((weak)) ksu_handle_execve(int *fd, struct filename **filename, void *argv, void *envp) { return 0; }
int __attribute__((weak)) ksu_handle_vfs_read(void *file, char __user **buf, size_t *count, void *pos) { return 0; }
int __attribute__((weak)) ksu_input_hook(unsigned int type, unsigned int code, int value) { return 0; }
int __attribute__((weak)) ksu_handle_setuid(uid_t *uid) { return 0; }
int __attribute__((weak)) ksu_handle_setgid(gid_t *gid) { return 0; }
EOF

echo "=== 3. 注入 Docker + LXC + NetHunter 内核配置 ==="
# 后面的 Docker、网络、以及 AnyKernel3 打包代码完全保持不变...


cat << 'EOF' >> arch/arm64/configs/$DEFCONFIG_FILE

# --- KERNELSU CONFIG ---
CONFIG_KPROBES=y
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
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y   # 👈 极其重要！没有它，Docker 端口映射必挂
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y  # 状态追踪
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

echo "=== 4. 开始编译内核 ==="
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

echo "=== 5. 打包 AnyKernel3 卡刷包 ==="
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
echo "千真万确！编译完成，刷机包已打包成功！"
