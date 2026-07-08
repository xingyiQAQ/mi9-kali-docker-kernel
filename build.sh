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

echo "=== 3. 预先生成配置，解决 O=out 带来的 .config 缺失断层 ==="
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

# 复制到根目录，消除 setup.sh 内的 grep 警告
cp out/.config .config
cd ..

echo "=== 4. 跨路径精准注入桩函数与高通总线/KSU 终极闭环 ==="

cat << 'EOF' >> kernel/kernel/sys.c

/* ==================== 彻底火化老旧/混血 KSU 硬编码符号 ==================== */
int ksu_handle_faccessat(void *dfd, const void *filename, void *mode, void *flags) { return 0; }
int ksu_handle_execve(void *fd, void *filename, void *argv, void *envp) { return 0; }
int ksu_handle_vfs_read(void *file, void *buf, void *count, void *pos) { return 0; }
int ksu_input_hook(unsigned int type, unsigned int code, int value) { return 0; }
int ksu_handle_setuid(void *uid) { return 0; }
int ksu_handle_setgid(void *gid) { return 0; }

/* ==================== 高通 RPMH 总线 Tracepoint 终极对齐天团 ==================== */
#include <linux/types.h>
#include <linux/export.h>
#include <linux/tracepoint.h>

struct tracepoint __tracepoint_bus_update_request;
EXPORT_SYMBOL_GPL(__tracepoint_bus_update_request);
void __scm_init_trace_bus_update_request(void) {}
EXPORT_SYMBOL_GPL(__scm_init_trace_bus_update_request);

struct tracepoint __tracepoint_bus_client_status;
EXPORT_SYMBOL_GPL(__tracepoint_bus_client_status);
void __scm_init_trace_bus_client_status(void) {}
EXPORT_SYMBOL_GPL(__scm_init_trace_bus_client_status);

struct tracepoint __tracepoint_bus_bcm_client_status;
EXPORT_SYMBOL_GPL(__tracepoint_bus_bcm_client_status);
void __scm_init_trace_bus_bcm_client_status(void) {}
EXPORT_SYMBOL_GPL(__scm_init_trace_bus_bcm_client_status);
EOF

find kernel/ -type f \( -name "*.c" -o -name "*.h" -o -name "Makefile" -o -name "Kconfig" \) ! -path "kernel/drivers/kernelsu/*" -exec sed -i 's/CONFIG_KSU/CONFIG_KSU_MANUAL_HOOK/g' {} +

echo "=== 5. 注入 Docker + LXC + NetHunter + KSU 核心内核配置 ==="
APPEND_CONFIGS=$(cat << 'EOF'
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
)

echo "$APPEND_CONFIGS" >> kernel/arch/arm64/configs/$DEFCONFIG_FILE
echo "$APPEND_CONFIGS" >> kernel/out/.config
echo "$APPEND_CONFIGS" >> kernel/.config

echo "=== 6. 开始整洁编译 ==="
cd kernel
make O=out $DEFCONFIG_FILE
make O=out "${MAKE_FLAGS[@]}" -j$(nproc)

echo "=== 7. 智能扫描与 AnyKernel3 卡刷包打包 ==="
cd ..
git clone https://github.com/osm0sis/AnyKernel3.git
sed -i 's/device.name1=/device.name1=cepheus/g' AnyKernel3/anykernel.sh

# 打印生成目录列表，方便在 Actions 日志中排查具体文件名
echo ">>> 正在盘点 out/arch/arm64/boot/ 下的编译产物："
ls -la kernel/out/arch/arm64/boot/

# 智能捕获：只要存在 Image 开头的文件，不管有没有后置扩展名，通通复制进 AnyKernel3
FOUND_IMAGE=0
for file in kernel/out/arch/arm64/boot/Image*; do
    if [ -f "$file" ]; then
        cp -v "$file" AnyKernel3/
        FOUND_IMAGE=1
    fi
done

# 顺便检查是否有独立生成的 dtbo.img，高通新内核打包经常也需要它
if [ -f "kernel/out/arch/arm64/boot/dtbo.img" ]; then
    cp -v "kernel/out/arch/arm64/boot/dtbo.img" AnyKernel3/
fi

if [ $FOUND_IMAGE -eq 0 ]; then
    echo "❌ 错误：在编译输出目录中完全没有发现任何以 Image 开头的内核镜像！"
    exit 1
fi

cd AnyKernel3
zip -r9 ../docker-ksu-nethunter-kernel-cepheus.zip *
echo "🎉 诸神退散，大功告成！卡刷包已完美生成，直接起飞！"
