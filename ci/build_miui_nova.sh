#!/bin/bash
# Xiaomi Pad 5 Pro 12.4 (dagu) - MIUI/HyperOS 内核构建脚本
# 复刻上游 liyafe1997 build.sh 的 MIUI 分支：SukiSU-Ultra + SUSFS(树内) + KPM 0.12.0
# 这是作者在 dagu (HyperOS 2.0 / Android 14) 上验证过可开机、可 root 的官方组合
set -e

TARGET_DEVICE=${TARGET_DEVICE:-dagu}
TOOLCHAIN_PATH=${TOOLCHAIN_PATH:-$HOME/proton-clang/proton-clang-20210522/bin}
# 定位用开关：KSU_ENABLE=false 出纯原版基线包；KPM_ENABLE=false 跳过 Image patch
KSU_ENABLE=${KSU_ENABLE:-true}
SUSFS_ENABLE=${SUSFS_ENABLE:-true}
KPM_ENABLE=${KPM_ENABLE:-true}
# Root 实现：ultra = SukiSU-Ultra(旧实现, 手动 hook + 树内 SUSFS)
#            nova = SukiSU-Nova(新实现, syscall hook + 自带隐藏, 管理器包名 com.sukisu.nova)
KSU_MODE=${KSU_MODE:-ultra}
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

# ---------------- SukiSU (Ultra / Nova) ----------------
if [ "$KSU_ENABLE" = "true" ] && [ "$KSU_MODE" = "nova" ]; then
    # SukiSU-Nova 的 builtin-new 分支：专为"内置进内核树"设计，自带 4.14+ 兼容层
    # （自动探测 selinux_state / strscpy / probe_kernel_* / TWA_RESUME 等新 API，
    #   缺失时回退老实现；Kbuild 还会读取树内 susfs.h 的 SUSFS_VERSION）。
    # builtin-new 默认走 syscall 表挂钩（KSU_TAMPER_SYSCALL_TABLE），不需要源码内联调用点；
    # 树内为 Ultra 预留的 ksu_handle_* / ksu_execveat_hook 调用点全部用 KSU_NOVA_MODE 排除，
    # 避免链接期未定义符号。
    echo "Guarding in-tree hook call sites for Nova..."
    for f in fs/exec.c fs/open.c fs/stat.c fs/read_write.c drivers/input/input.c drivers/tty/pty.c; do
        [ -f "$f" ] && sed -i 's/^#ifdef CONFIG_KSU$/#if defined(CONFIG_KSU) \&\& !defined(KSU_NOVA_MODE)/' "$f"
    done
    echo "Cloning SukiSU-Nova (builtin-new)..."
    rm -rf KernelSU
    git clone --depth=1 -b builtin-new https://github.com/SukiSU-Nova/SukiSU-Nova KernelSU
    # builtin-new 的 supercall 引用了 SUSFS v2.5+ 才有的 CMD_SUSFS_SET_SUS_PATH_UID_FILTER，
    # 树内 v2.3.0 无该命令，删除对应 case（3 行）以免编译/链接失败
    sed -i '/CMD_SUSFS_SET_SUS_PATH_UID_FILTER/,+2d' KernelSU/kernel/supercall/supercall.c 2>/dev/null || true
    ln -sf "$(realpath --relative-to=drivers KernelSU/kernel)" drivers/kernelsu
    grep -q "kernelsu" drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    echo "SukiSU-Nova (builtin-new) integrated."

    # 恢复完整 SUSFS v2.x：从 fork 历史 commit 取 SUSFS 相关文件（该 commit 的树是
    # SUSFS v2.3.0，正好满足 builtin-new 的 supercall 期望，例如 SUSFS_MAGIC/ADD_SUS_MAP）
    if [ "${SUSFS_ENABLE:-true}" = "true" ]; then
        SUSFS_SRC=3917fc9cd8a43b0b842013a5ee33bc990c093d63
        git fetch --depth=1 origin "$SUSFS_SRC" 2>/dev/null || true
        if git cat-file -e "$SUSFS_SRC^{commit}" 2>/dev/null; then
            echo "Restoring SUSFS v2.x files from $SUSFS_SRC ..."
            # 取"并集"：当前树里含 susfs 的文件 + 源 commit 里含 susfs 的文件，
            # 都统一对齐到源 commit 版本，避免 v1.5.7/v2.x 两套 hook 混用导致宏不匹配。
            CUR_FILES=$(git grep -l -i "susfs" -- fs include kernel mm drivers 2>/dev/null)
            SRC_FILES=$(git grep -l -i "susfs" "$SUSFS_SRC" -- fs include kernel mm drivers 2>/dev/null | sed "s|^$SUSFS_SRC:||")
            ALL_FILES=$(printf "%s\n%s\n" "$CUR_FILES" "$SRC_FILES" | sort -u | sed '/^$/d')
            echo "  aligning $(echo "$ALL_FILES" | wc -l) susfs files to source version"
            echo "$ALL_FILES" | while read -r f; do
                [ -n "$f" ] && git cat-file -e "$SUSFS_SRC:$f" 2>/dev/null && git checkout "$SUSFS_SRC" -- "$f" 2>/dev/null
            done
            # builtin-new 的 ksu.c 引用了 SUSFS v2.4 才有的两个函数，v2.3.0 未实现，补桩避免链接失败
            if [ -f fs/susfs.c ] && ! grep -q "susfs_add_sus_type" fs/susfs.c; then
                cat >> fs/susfs.c <<'SUSFS_SHIM_EOF'

/* v2.4 compat shims for SukiSU-Nova builtin-new */
int susfs_add_sus_type(void *user_info)
{
	return -EINVAL;
}
int susfs_parse_sus_path_app_strings(char *app_strings)
{
	return 0;
}
SUSFS_SHIM_EOF
                echo "  added v2.4 compat shims to fs/susfs.c"
            fi
            echo "  changed files: $(git status --porcelain | wc -l)"
        else
            echo "  [warn] SUSFS source commit unavailable; building without SUSFS"
        fi
    fi
elif [ "$KSU_ENABLE" = "true" ]; then
    echo "Applying SukiSU-Ultra (kernel commit f4863b20)..."
    curl -LSs "https://github.com/liyafe1997/SukiSU-Ultra/raw/4ff14cf0051d04209c4abd5027d99d8e7780ef5b/kernel/setup.sh" | bash -s f4863b20cc8dc0f8cc67418980f022e43014b598
else
    echo "KSU_ENABLE=false：构建纯原版基线（不集成 KernelSU）"
fi

# ---------------- 性能/功能调优 (PERF_ENABLE) ----------------
# 用 sed/perl 精确改数值：不依赖补丁上下文、可重复执行（幂等）。
# PERF_ENABLE=false 时全部跳过，保持官方原版行为。
if [ "${PERF_ENABLE:-true}" = "true" ]; then
    echo "=== Applying performance tunings ==="

    # 1) cpu-boost：轻度触控 boost（仅在触控瞬间拉频，功耗可控，提升跟手度）
    #    不使用激进值，保持"流畅 + 省电"平衡
    CB=drivers/cpufreq/cpu-boost.c
    if [ -f "$CB" ] && ! grep -q "perf: input boost defaults" "$CB"; then
        perl -0pi -e 's/(\t\ts->cpu = cpu;\n)/$1\t\t\/* perf: input boost defaults *\/\n\t\tif (cpu <= 3) {\n\t\t\ts->input_boost_freq = 1036800;\n\t\t\ts->powerkey_input_boost_freq = 1228800;\n\t\t} else if (cpu <= 6) {\n\t\t\ts->input_boost_freq = 1324800;\n\t\t\ts->powerkey_input_boost_freq = 1516800;\n\t\t} else {\n\t\t\ts->input_boost_freq = 1516800;\n\t\t\ts->powerkey_input_boost_freq = 1804800;\n\t\t}\n/' $CB
        grep -q "perf: input boost defaults" $CB && echo "  [ok] cpu-boost light defaults" || { echo "  [FAIL] cpu-boost insert"; exit 1; }
    fi

    # 2) 块设备 readahead 128K -> 512K（IO 更快完成，减少等待与唤醒，兼顾流畅省电）
    BC=block/blk-core.c
    if [ -f "$BC" ] && ! grep -q "4 \* VM_MAX_READAHEAD" "$BC"; then
        perl -0pi -e 's{\tq->backing_dev_info->ra_pages =\n\t\t\t\(VM_MAX_READAHEAD \* 1024\) / PAGE_SIZE;\n\tq->backing_dev_info->io_pages =\n\t\t\t\(VM_MAX_READAHEAD \* 1024\) / PAGE_SIZE;}{\tq->backing_dev_info->ra_pages =\n\t\t\t(4 * VM_MAX_READAHEAD * 1024) / PAGE_SIZE;\n\tq->backing_dev_info->io_pages =\n\t\t\t(4 * VM_MAX_READAHEAD * 1024) / PAGE_SIZE;}' $BC
        grep -q "4 \* VM_MAX_READAHEAD" $BC && echo "  [ok] readahead 512K" || echo "  [warn] readahead pattern mismatch"
    fi

    # 3) schedutil 适度提频（比原厂略积极，远低于激进值，兼顾流畅与功耗）
    #    hispeed 门槛 90->85；金核/大核 rtg boost 0 -> 1.3/1.6GHz
    SU=kernel/sched/cpufreq_schedutil.c
    if [ -f "$SU" ]; then
        sed -i 's/^#define DEFAULT_HISPEED_LOAD 90$/#define DEFAULT_HISPEED_LOAD 85/' $SU
        sed -i 's/^#define DEFAULT_CPU4_RTG_BOOST_FREQ 0$/#define DEFAULT_CPU4_RTG_BOOST_FREQ 1324800/' $SU
        sed -i 's/^#define DEFAULT_CPU7_RTG_BOOST_FREQ 0$/#define DEFAULT_CPU7_RTG_BOOST_FREQ 1612800/' $SU
        grep -q "DEFAULT_HISPEED_LOAD 85" $SU && echo "  [ok] schedutil mild boost" || echo "  [warn] schedutil pattern mismatch"
    fi

    # 4) GPU idle-timeout 80->50ms（更快拉到目标频率，减少掉帧；不抬高上限故不增满载功耗）
    GD=arch/arm64/boot/dts/vendor/qcom/kona-gpu.dtsi
    if [ -f "$GD" ]; then
        sed -i 's/qcom,idle-timeout = <80>;/qcom,idle-timeout = <50>;/' $GD
        grep -q "qcom,idle-timeout = <50>;" $GD && echo "  [ok] gpu idle-timeout 50ms" || echo "  [warn] gpu idle-timeout mismatch"
    fi
else
    echo "PERF_ENABLE=false：不应用性能调优"
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

# 崩溃日志：pstore/ramoops（在 dtb 预留 1MB，panic 后可从 /sys/fs/pstore 取调用栈）
if [ "${PSTORE_ENABLE:-false}" = "true" ]; then
    for f in arch/arm64/boot/dts/vendor/qcom/kona*.dts arch/arm64/boot/dts/vendor/qcom/kona*.dtsi; do
        [ -f "$f" ] || continue
        grep -q "ramoops_region" "$f" && continue
        grep -q "reserved-memory {" "$f" || continue
        # 必须插在 reserved-memory 的属性（#address-cells/#size-cells/ranges）之后，
        # 否则 dtc 会报 "Properties must precede subnodes"
        awk '{print} /reserved-memory \{/{inres=1} inres && /^[ \t]*ranges;[ \t]*$/{printf "\t\tramoops_mem: ramoops_region@9fe00000 {\n\t\t\tcompatible = \"ramoops\";\n\t\t\treg = <0x0 0x9fe00000 0x0 0x100000>;\n\t\t\trecord-size = <0x20000>;\n\t\t\tconsole-size = <0x60000>;\n\t\t\tpmsg-size = <0x20000>;\n\t\t\tno-map;\n\t\t};\n"; inres=0}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        echo "pstore: injected ramoops node into $f"
    done
fi

make $MAKE_ARGS ${TARGET_DEVICE}_defconfig
# SukiSU-Nova (builtin-new)：先只开内核核心 + KPM（需 KPROBES）。
# 注意：builtin-new 的 supercall 期望 SUSFS v2.x（SUSFS_MAGIC/ADD_SUS_MAP 等），
# 而当前树内是 v1.5.7；故先关闭 KSU_SUSFS 以保证编译与开机（Nova 自带的
# mount_hide/sucompat 等隐藏仍然生效）。确认可用后再单独升级树内 SUSFS 到 v2.x。
if [ "$KSU_ENABLE" = "true" ] && [ "$KSU_MODE" = "nova" ]; then
    if [ "${SUSFS_ENABLE:-true}" = "true" ] && grep -q "SUSFS_MAGIC" include/linux/susfs_def.h 2>/dev/null; then
        echo "Enabling KSU_SUSFS (v2.x detected)"
        scripts/config --file out/.config \
        -e KSU \
        -e KSU_TAMPER_SYSCALL_TABLE \
        -e KSU_LSM_SECURITY_HOOKS \
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
        -e KSU_SUSFS_PRIORITY_UID_FILTER \
        -e KPM \
        -e KPROBES
    else
        echo "SUSFS v2.x not present; building Nova without KSU_SUSFS"
        scripts/config --file out/.config \
        -e KSU \
        -e KSU_TAMPER_SYSCALL_TABLE \
        -e KSU_LSM_SECURITY_HOOKS \
        -d KSU_SUSFS \
        -e KPM \
        -e KPROBES
    fi
# SukiSU-Ultra: KSU(MANUAL_HOOK) + SUSFS(树内) + KPM —— 与上游 build.sh 逐项一致
elif [ "$KSU_ENABLE" = "true" ]; then
    scripts/config --file out/.config \
    -e KSU \
    -e KSU_MANUAL_HOOK \
    -e KSU_SUSFS_HAS_MAGIC_MOUNT \
    -d KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -d KSU_SUSFS_SUS_OVERLAYFS \
    -e KSU_SUSFS_TRY_UMOUNT \
    -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -d KSU_SUSFS_OPEN_REDIRECT \
    -d KSU_SUSFS_SUS_SU \
    -e KPM
else
    scripts/config --file out/.config -d KSU
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
# 性能优化（参考 lly Realking 等 kona 内核的通行做法）：
#  - HZ_300：调度粒度更细，交互更平滑（功耗代价约 1~3%）
#  - TCP BBR 设为默认（移动网络吞吐/延迟更好），其余算法保留可切换
if [ "${PERF_ENABLE:-true}" = "true" ]; then
    scripts/config --file out/.config \
        -e HZ_300 \
        -d HZ_100 \
        -e TCP_CONG_ADVANCED \
        -e TCP_CONG_BBR \
        -e TCP_CONG_WESTWOOD \
        -e TCP_CONG_BIC \
        -e TCP_CONG_HTCP \
        -e TCP_CONG_VENO \
        --set-str DEFAULT_TCP_CONG bbr
fi
# Nova 面向新内核，4.19 上会有若干“仅告警”级别的差异，降级为 warning
KCFLAGS="-Wno-error=macro-redefined -Wno-error=unused-variable -Wno-error=unused-function -Wno-error=misleading-indentation -Wno-error=address-of-packed-member -Wno-unknown-warning-option"
# Nova 模式：定义 KSU_NOVA_MODE，使树内 Ultra 的手动 hook 调用点被排除
if [ "$KSU_ENABLE" = "true" ] && [ "$KSU_MODE" = "nova" ]; then
    KCFLAGS="$KCFLAGS -DKSU_NOVA_MODE"
fi
if [ "${PSTORE_ENABLE:-false}" = "true" ]; then
    scripts/config --file out/.config -e PSTORE -e PSTORE_RAM -e PSTORE_CONSOLE -e PSTORE_PMSG -e PSTORE_FTRACE
fi
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

# KPM 支持：
#  - Ultra：对 Image 打 patch（SukiSU-Ultra 0.12.0）
#  - Nova ：KPM 已编译进 kernelsu.o，无需 patch_linux
if [ "$KSU_ENABLE" = "true" ] && [ "$KPM_ENABLE" = "true" ] && [ "$KSU_MODE" != "nova" ]; then
cd out/arch/arm64/boot/
wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
chmod +x patch_linux
./patch_linux
rm Image
mv oImage Image
cd -
else
echo "跳过 KPM Image patch (KSU_ENABLE=$KSU_ENABLE KPM_ENABLE=$KPM_ENABLE KSU_MODE=$KSU_MODE)"
fi

cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

sed -i "s/-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf/-perf/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

cd anykernel
KSU_BRAND="Ultra"
[ "$KSU_MODE" = "nova" ] && KSU_BRAND="Nova"
ZIP_FILENAME=Kernel_MIUI_${TARGET_DEVICE}_SukiSU-${KSU_BRAND}${VARIANT}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
mv $ZIP_FILENAME ../
cd ..
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
