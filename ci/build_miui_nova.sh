#!/bin/bash
# Xiaomi Pad 5 Pro 12.4 (dagu) - MIUI/HyperOS 内核构建脚本
# 基于 liyafe1997/kernel_xiaomi_sm8250_mod 的 build.sh MIUI 分支逻辑，
# 将 KernelSU 替换为 SukiSU Nova (builtin 分支 / 手动 hook 模式)
set -e

TARGET_DEVICE=${TARGET_DEVICE:-dagu}
TOOLCHAIN_PATH=${TOOLCHAIN_PATH:-$HOME/proton-clang/proton-clang-20210522/bin}
# 定位用开关：KSU_ENABLE=false 出纯原版基线包；KPM_ENABLE=false 跳过 Image patch
KSU_ENABLE=${KSU_ENABLE:-true}
SUSFS_ENABLE=${SUSFS_ENABLE:-true}
KPM_ENABLE=${KPM_ENABLE:-true}
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)

if [ ! -d "$TOOLCHAIN_PATH" ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    exit 1
fi
export PATH="$TOOLCHAIN_PATH:$PATH"

for bin in aarch64-linux-gnu-ld arm-linux-gnueabi-ld clang; do
    if ! command -v $bin >/dev/null 2>&1; then
        echo "[$bin] does not exist, please check your environment."
        exit 1
    fi
done
clang --version

# ccache 加速
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"

MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

# ---------------- SukiSU Nova ----------------
# builtin-new 分支：面向 3.10~7.1 的 downstream 内核，自带 4.19 兼容层
# （kernel_compat.h 提供 strncpy_from_user_nofault / 三参数 access_ok 等 shim，
#   sucompat 走 ARM64 inline branch-link hook，无需源码里保留手动 hook）
if [ "$KSU_ENABLE" = "true" ]; then
if [ ! -d KernelSU ]; then
    git clone --depth=1 -b builtin-new https://github.com/SukiSU-Nova/SukiSU-Nova KernelSU
fi
# 本内核源码已内置 SukiSU 风格的手动 hook 调用点，它们用这三个开关变量门控；
# Nova builtin-new 只 extern 引用不定义，这里补上默认开启（走手动 hook 路径）
cat >> KernelSU/kernel/ksu.c <<'EOF'

/* downstream 4.19: 手动 hook 开关（由内核源码里的 ksu_*_hook 调用点使用） */
bool ksu_execveat_hook __read_mostly = true;
bool ksu_vfs_read_hook __read_mostly = true;
bool ksu_input_hook __read_mostly = true;
EOF
ln -sfn "$(realpath --relative-to=drivers KernelSU/kernel)" drivers/kernelsu
grep -q "kernelsu" drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
else
echo "KSU_ENABLE=false：构建纯原版基线（不集成 KernelSU）"
fi

echo "Cleaning..."
rm -rf out/
rm -rf anykernel/
echo "Clone AnyKernel3 for packing kernel"
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# 本地版本号带日期/commit，便于识别
sed -i "s/-perf/-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

# ---------------- Building for MIUI ----------------
dts_source=arch/arm64/boot/dts/vendor/qcom
cp -a ${dts_source} .dts.bak
# Correct panel dimensions on MIUI builds
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*
# Enable back mi smartfps while disabling qsync min refresh-rate
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*
# Enable back refresh rates supported on MIUI
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
# Enable back brightness control from dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

make $MAKE_ARGS ${TARGET_DEVICE}_defconfig
# SukiSU Nova: KSU + SUSFS v2.3.0 + KPM（可用环境变量裁剪，便于二分定位）
if [ "$KSU_ENABLE" = "true" ]; then
    scripts/config --file out/.config -e KSU
    # 走源码里的手动 hook 调用点 + LSM hook，关闭运行期改写指令的后端
    scripts/config --file out/.config -e KSU_LSM_SECURITY_HOOKS \
        -d KSU_HACK_ARM64_BRANCH_LINK -d KSU_TAMPER_SYSCALL_TABLE
    if [ "$SUSFS_ENABLE" = "true" ]; then
        scripts/config --file out/.config \
            -e KSU_SUSFS \
            -e KSU_SUSFS_INLINE_HOOK \
            -e KSU_SUSFS_SUS_PATH \
            -e KSU_SUSFS_SUS_MOUNT \
            -e KSU_SUSFS_SUS_KSTAT \
            -e KSU_SUSFS_SPOOF_UNAME \
            -e KSU_SUSFS_ENABLE_LOG \
            -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
            -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
            -e KSU_SUSFS_OPEN_REDIRECT \
            -e KSU_SUSFS_SUS_MAP \
            -e KSU_SUSFS_PRIORITY_UID_FILTER
    else
        scripts/config --file out/.config -d KSU_SUSFS
    fi
    if [ "$KPM_ENABLE" = "true" ]; then
        scripts/config --file out/.config -e KPM
    else
        scripts/config --file out/.config -d KPM
    fi
fi
# MIUI 专用配置
scripts/config --file out/.config \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -e PERF_CRITICAL_RT_TASK	\
    -e SF_BINDER		\
    -e OVERLAY_FS		\
    -d DEBUG_FS \
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MIHW \
    -e PACKAGE_RUNTIME_INFO \
    -e BINDER_OPT \
    -e KPERFEVENTS \
    -e MILLET \
    -e PERF_HUMANTASK \
    -d LTO_CLANG \
    -d LOCALVERSION_AUTO \
    -e SF_BINDER \
    -e XIAOMI_MIUI \
    -d MI_MEMORY_SYSFS \
    -e TASK_DELAY_ACCT \
    -e MIUI_ZRAM_MEMORY_TRACKING \
    -d CONFIG_MODULE_SIG_SHA512 \
    -d CONFIG_MODULE_SIG_HASH \
    -e MI_FRAGMENTION \
    -e PERF_HELPER \
    -e BOOTUP_RECLAIM \
    -e MI_RECLAIM \
    -e RTMM
# Nova 面向新内核，4.19 上会有若干“仅告警”级别的差异，降级为 warning
KCFLAGS="-Wno-error=macro-redefined -Wno-error=unused-variable -Wno-error=unused-function -Wno-error=misleading-indentation -Wno-error=address-of-packed-member -Wno-unknown-warning-option"
make $MAKE_ARGS KCFLAGS="$KCFLAGS" -j$(nproc)

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "out/arch/arm64/boot/Image does not exist. MIUI build failed."
    exit 1
fi
echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

# 恢复 dts 修改
rm -rf ${dts_source}
mv .dts.bak ${dts_source}
rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/

# KPM 支持：对 Image 打 patch
if [ "$KSU_ENABLE" = "true" ] && [ "$KPM_ENABLE" = "true" ]; then
cd out/arch/arm64/boot/
wget -q https://github.com/SukiSU-Nova/SukiSU_KernelPatch_patch/releases/download/0.14.0/patch_linux
chmod +x patch_linux
./patch_linux
rm Image
mv oImage Image
cd -
else
echo "跳过 KPM Image patch (KSU_ENABLE=$KSU_ENABLE KPM_ENABLE=$KPM_ENABLE)"
fi

cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

sed -i "s/-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf/-perf/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

cd anykernel
ZIP_FILENAME=Kernel_MIUI_${TARGET_DEVICE}_SukiSU-Nova${VARIANT}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
mv $ZIP_FILENAME ../
cd ..
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
