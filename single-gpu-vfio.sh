#!/usr/bin/env bash
# Arch/EndeavourOS + GRUB + NVIDIA single-GPU passthrough installer/manager.
#
# This script intentionally keeps the host NVIDIA driver active at boot.  The
# GPU is released only while the selected libvirt guest is running, then bound
# back to the host when the guest powers off.
set -Eeuo pipefail
export LC_ALL=C

readonly VERSION="1.0.0"
readonly INSTALLED_TOOL="/usr/local/sbin/single-gpu-vfio"
readonly CONFIG_FILE="/etc/single-gpu-vfio.conf"
readonly HOOK_FILE="/etc/libvirt/hooks/qemu.d/10-single-gpu-vfio"
readonly BACKUP_DIR="/var/lib/single-gpu-vfio/backups"

log()  { printf '[single-gpu-vfio] %s\n' "$*"; }
warn() { printf '[single-gpu-vfio] WARNING: %s\n' "$*" >&2; }
die()  { printf '[single-gpu-vfio] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
single-gpu-vfio 1.0.0

Arch/EndeavourOS、GRUB、NVIDIA 单显卡直通配置工具。

首次安装：
  sudo ./single-gpu-vfio.sh install \
    --vm-name omarchy-vfio \
    --iso /absolute/path/to/installer.iso \
    --gpu 0000:01:00.0 \
    --audio 0000:01:00.1 \
    --usb 0000:00:14.0 \
    --disk /absolute/path/to/guest.qcow2 \
    --disk-size 40G --memory 8192 --vcpus 4

install 选项：
  --vm-name NAME             虚拟机名称（默认：single-gpu-vm）
  --iso PATH                 安装 ISO，必填
  --rom PATH                 已导出的 ROM；省略时自动调用 nvflash 提取
  --nvflash PATH             nvflash 可执行文件（默认从 PATH 自动寻找）
  --nvflash-index N          nvflash 显卡序号（单显卡默认：0）
  --gpu BDF                  GPU PCI 地址；省略时自动选择第一块 NVIDIA VGA/3D 设备
  --audio BDF                GPU HDMI 音频 PCI 地址；省略时尝试自动寻找
  --usb BDF                  要整体直通的 USB 控制器，必填
  --disk PATH                qcow2 路径（默认：/var/lib/libvirt/images/NAME.qcow2）
  --disk-size SIZE           新磁盘大小（默认：40G）
  --memory MiB               内存（默认：8192）
  --vcpus N                  vCPU（默认：4）
  --user NAME                图形会话用户（默认：SUDO_USER）
  --display-manager SERVICE  默认自动检测 greetd/sddm/gdm/lightdm
  --gpu-services LIST        交接前停止的服务，逗号分隔；默认自动加入 lactd
  --yes                      跳过 IOMMU 分组确认
  --allow-existing-hooks     允许系统中已有其他 VFIO hook（可能冲突）
  --skip-packages            不安装软件包

若省略 --rom，工具会优先使用 PATH 中的 nvflash。若尚未安装并检测到
yay/paru，工具会在确认后用普通用户从 AUR 安装 nvflash，再自动提取。

安装后的管理命令：
  sudo single-gpu-vfio detect       显示可用 PCI 设备和环境
  sudo single-gpu-vfio check        完整只读检查
  sudo single-gpu-vfio test [秒]    定时停止并恢复的首次测试（默认 90 秒）
  sudo single-gpu-vfio start        正式启动，不设自动停止
  sudo single-gpu-vfio shutdown     向来宾发送正常关机请求
  sudo single-gpu-vfio force-stop   强制关闭无响应的来宾
  sudo single-gpu-vfio recover      来宾关闭后手动恢复宿主显卡
  sudo single-gpu-vfio eject-iso    关机状态下弹出安装 ISO
  sudo single-gpu-vfio status       显示虚拟机、设备和最近 hook 日志
  sudo single-gpu-vfio remove       移除定义与 hook；保留磁盘和 ROM

重要：
  * test/start 会结束当前图形会话，请先保存工作。
  * 正常退出请在来宾内选择“关机”；Ctrl+Alt+Delete 通常只是重启来宾。
  * force-stop 相当于拔掉虚拟机电源，只用于来宾完全无响应时。
EOF
}

require_root() {
    (( EUID == 0 )) || die "此命令必须通过 sudo 或 pkexec 以 root 运行。"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

confirm() {
    local prompt="$1"
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    [[ -t 0 ]] || die "$prompt（非交互模式请添加 --yes）"
    local answer
    read -r -p "$prompt [输入 YES 继续]: " answer
    [[ "$answer" == "YES" ]] || die "已取消。"
}

normalize_bdf() {
    local value="${1,,}"
    if [[ "$value" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
        value="0000:$value"
    fi
    [[ "$value" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || \
        die "无效 PCI 地址：$1（示例：0000:01:00.0）"
    printf '%s\n' "$value"
}

pci_driver() {
    local path="/sys/bus/pci/devices/$1/driver"
    [[ -L "$path" ]] && basename "$(readlink -f "$path")" || printf '%s' 'unbound'
}

pci_class() {
    local path="/sys/bus/pci/devices/$1/class"
    [[ -r "$path" ]] && tr -d '\n' <"$path" || printf '%s' 'unknown'
}

pci_xml_address() {
    local bdf="$1"
    local domain="${bdf%%:*}"
    local rest="${bdf#*:}"
    local bus="${rest%%:*}"
    local slot_function="${rest#*:}"
    local slot="${slot_function%%.*}"
    local function="${slot_function#*.}"
    printf '<address domain="0x%s" bus="0x%s" slot="0x%s" function="0x%s"/>' \
        "$domain" "$bus" "$slot" "$function"
}

xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" <<<"$1"
}

config_value() {
    printf '%s=%q\n' "$1" "$2"
}

load_config() {
    [[ -r "$CONFIG_FILE" ]] || die "尚未安装配置：$CONFIG_FILE"
    # The file is generated root-owned and mode 0600 by this tool.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

state_dir() {
    local safe_name="${VM_NAME//[^A-Za-z0-9_.-]/_}"
    printf '/run/libvirt/single-gpu-vfio-%s\n' "$safe_name"
}

hook_log_file() {
    local safe_name="${VM_NAME//[^A-Za-z0-9_.-]/_}"
    printf '/var/log/libvirt/single-gpu-vfio-%s.log\n' "$safe_name"
}

detect_display_manager() {
    local linked=''
    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        linked="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")"
        [[ "$linked" == *.service ]] && { printf '%s\n' "$linked"; return; }
    fi
    local service
    for service in greetd.service sddm.service gdm.service lightdm.service lxdm.service; do
        if systemctl is-active --quiet "$service" 2>/dev/null || \
           systemctl is-enabled --quiet "$service" 2>/dev/null; then
            printf '%s\n' "$service"
            return
        fi
    done
    die "无法自动检测显示管理器，请使用 --display-manager 指定。"
}

detect_gpu() {
    lspci -Dnn | awk '
        /NVIDIA/ && (/VGA compatible controller/ || /3D controller/) { print $1; exit }
    '
}

detect_gpu_audio() {
    local gpu="$1"
    local prefix="${gpu%.*}"
    local candidate
    while read -r candidate; do
        [[ "${candidate%.*}" == "$prefix" ]] && { printf '%s\n' "$candidate"; return; }
    done < <(lspci -Dnn | awk '/NVIDIA/ && /Audio device/ {print $1}')
}

iommu_active() {
    compgen -G '/sys/kernel/iommu_groups/*/devices/*' >/dev/null 2>&1
}

show_iommu_group() {
    local bdf="$1"
    local group_path
    group_path="$(readlink -f "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null || true)"
    if [[ -z "$group_path" || ! -d "$group_path/devices" ]]; then
        printf '  %s: no IOMMU group\n' "$bdf"
        return 1
    fi
    printf '  %s: group %s\n' "$bdf" "${group_path##*/}"
    local member
    for member in "$group_path"/devices/*; do
        lspci -Dnn -s "${member##*/}" | sed 's/^/    /'
    done
}

show_detection() {
    require_command lspci
    log "版本：$VERSION"
    printf '\n系统：\n'
    sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null || true
    printf '内核：%s\n' "$(uname -r)"
    printf '启动参数：%s\n' "$(< /proc/cmdline)"
    printf 'IOMMU 分组：%s\n' "$(iommu_active && printf active || printf inactive)"
    printf '\nNVIDIA 显卡/音频：\n'
    lspci -Dnnk | rg -A3 -i '(VGA compatible controller|3D controller|Audio device).*NVIDIA|NVIDIA.*(VGA compatible controller|3D controller|Audio device)' || true
    printf '\nUSB 控制器：\n'
    lspci -Dnnk | rg -A3 'USB controller' || true
    printf '\n显示管理器候选：\n'
    local service
    for service in greetd.service sddm.service gdm.service lightdm.service lxdm.service; do
        if systemctl list-unit-files "$service" --no-legend 2>/dev/null | grep -q .; then
            printf '  %-18s active=%-8s enabled=%s\n' "$service" \
                "$(systemctl is-active "$service" 2>/dev/null || true)" \
                "$(systemctl is-enabled "$service" 2>/dev/null || true)"
        fi
    done
}

install_packages() {
    [[ -e /etc/arch-release ]] || die "自动安装仅支持 Arch/EndeavourOS。"
    require_command pacman
    log "安装 KVM/libvirt/OVMF 依赖……"
    pacman -S --needed --noconfirm \
        qemu-desktop libvirt virt-manager edk2-ovmf swtpm dnsmasq \
        pciutils psmisc python ripgrep
    systemctl enable --now libvirtd.service
}

configure_grub_iommu() {
    [[ -f /etc/default/grub ]] || die "找不到 /etc/default/grub；此工具只自动配置 GRUB。"
    require_command grub-mkconfig

    local cpu_vendor iommu_param
    cpu_vendor="$(awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)"
    case "$cpu_vendor" in
        GenuineIntel) iommu_param='intel_iommu=on' ;;
        AuthenticAMD) iommu_param='amd_iommu=on' ;;
        *) die "未知 CPU 厂商：$cpu_vendor" ;;
    esac

    # shellcheck disable=SC1091
    source /etc/default/grub
    local current="${GRUB_CMDLINE_LINUX_DEFAULT:-}"
    local parameter
    for parameter in "$iommu_param" iommu=pt; do
        if [[ " $current " != *" $parameter "* ]]; then
            current="${current:+$current }$parameter"
        fi
    done

    install -d -m 0755 "$BACKUP_DIR"
    if [[ ! -e "$BACKUP_DIR/grub.before-single-gpu-vfio" ]]; then
        install -m 0644 /etc/default/grub "$BACKUP_DIR/grub.before-single-gpu-vfio"
    fi

    local escaped replacement temporary
    escaped="${current//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    replacement="GRUB_CMDLINE_LINUX_DEFAULT=\"$escaped\""
    temporary="$(mktemp /etc/default/grub.single-gpu-vfio.XXXXXX)"
    awk -v replacement="$replacement" '
        BEGIN { replaced=0 }
        /^GRUB_CMDLINE_LINUX_DEFAULT=/ { print replacement; replaced=1; next }
        { print }
        END { if (!replaced) print replacement }
    ' /etc/default/grub >"$temporary"
    install -o root -g root -m 0644 "$temporary" /etc/default/grub
    rm -f "$temporary"
    grub-mkconfig -o /boot/grub/grub.cfg
    log "GRUB 已加入 $iommu_param iommu=pt。"
}

prepare_rom() {
    local source_rom="$1" destination_rom="$2"
    [[ -f "$source_rom" ]] || die "ROM 不存在：$source_rom"
    require_command python3
    install -d -m 0755 "$(dirname "$destination_rom")"
    local temporary
    temporary="$(mktemp "$(dirname "$destination_rom")/.rom.XXXXXX")"

    local expected_vendor expected_device
    expected_vendor="$(<"/sys/bus/pci/devices/$GPU_BDF/vendor")"
    expected_device="$(<"/sys/bus/pci/devices/$GPU_BDF/device")"
    python3 - "$source_rom" "$temporary" "$expected_vendor" "$expected_device" <<'PY'
import pathlib
import struct
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
data = source.read_bytes()
expected_vendor = int(sys.argv[3], 16)
expected_device = int(sys.argv[4], 16)

def parse_chain(offset):
    images = []
    cursor = offset
    for _ in range(32):
        if cursor + 0x1a > len(data) or data[cursor:cursor + 2] != b"\x55\xaa":
            return None
        pcir_pointer = struct.unpack_from("<H", data, cursor + 0x18)[0]
        pcir = cursor + pcir_pointer
        if pcir + 0x16 > len(data) or data[pcir:pcir + 4] != b"PCIR":
            return None
        vendor, device = struct.unpack_from("<HH", data, pcir + 4)
        if not images and (vendor != expected_vendor or device != expected_device):
            return None
        image_length = struct.unpack_from("<H", data, pcir + 0x10)[0] * 512
        code_type = data[pcir + 0x14]
        indicator = data[pcir + 0x15]
        if image_length == 0 or cursor + image_length > len(data):
            return None
        images.append((cursor, image_length, code_type))
        if indicator & 0x80:
            return images
        cursor += image_length
    return None

chosen = None
for offset in range(0, max(0, len(data) - 1)):
    if data[offset:offset + 2] != b"\x55\xaa":
        continue
    chain = parse_chain(offset)
    if chain and any(code_type == 3 for _, _, code_type in chain):
        chosen = (offset, chain)
        break

if chosen is None:
    raise SystemExit("ROM 中未找到带 EFI GOP 的有效 PCI option-ROM 链")

offset, chain = chosen
destination.write_bytes(data[offset:])
print(f"ROM header offset: {offset}")
for index, (image_offset, image_length, code_type) in enumerate(chain, 1):
    kind = {0: "legacy", 3: "EFI"}.get(code_type, f"type-{code_type}")
    print(f"ROM image {index}: offset={image_offset-offset} length={image_length} {kind}")
PY

    install -o root -g root -m 0644 "$temporary" "$destination_rom"
    rm -f "$temporary"
    log "ROM 已安装：$destination_rom"
    sha256sum "$destination_rom"
}

extract_rom_nvflash() {
    local nvflash_bin="$1" nvflash_index="$2" destination_raw="$3"
    [[ -x "$nvflash_bin" ]] || die "nvflash 不可执行：$nvflash_bin"
    [[ "$nvflash_index" =~ ^[0-9]+$ ]] || die "--nvflash-index 必须是非负整数。"
    install -d -m 0755 "$(dirname "$destination_raw")"
    local temporary
    temporary="$(mktemp "$(dirname "$destination_raw")/.raw-rom.XXXXXX")"
    # nvflash refuses to read while the proprietary driver is loaded.  This
    # function runs from a root-owned transient systemd unit, so terminating
    # the graphical user session cannot kill the extraction job.
    if ! (
        set -Eeuo pipefail
        local -a active_services=() vtconsoles=()
        local display_manager_was_active=0
        restore_after_nvflash() {
            local rc=$?
            local recovery_failed=0
            trap - EXIT
            set +e
            modprobe nvidia
            modprobe nvidia_modeset
            modprobe nvidia_uvm
            modprobe nvidia_drm
            if [[ ! -L "/sys/bus/pci/devices/$GPU_BDF/driver" ]]; then
                printf '%s' "$GPU_BDF" >/sys/bus/pci/drivers_probe
            fi
            local vtconsole service
            for vtconsole in "${vtconsoles[@]}"; do
                [[ -w "/sys/class/vtconsole/$vtconsole/bind" ]] && \
                    printf '1' >"/sys/class/vtconsole/$vtconsole/bind"
            done
            for service in "${active_services[@]}"; do systemctl start "$service" || recovery_failed=1; done
            if (( display_manager_was_active )); then
                systemctl start "$DISPLAY_MANAGER" || recovery_failed=1
            fi
            [[ "$(pci_driver "$GPU_BDF")" == nvidia ]] || recovery_failed=1
            if (( rc == 0 && recovery_failed != 0 )); then rc=1; fi
            exit "$rc"
        }
        trap restore_after_nvflash EXIT

        local service
        for service in $GPU_SERVICES; do
            [[ -n "$service" ]] || continue
            if systemctl is-active --quiet "$service"; then
                active_services+=("$service")
                systemctl stop "$service"
            fi
        done
        if systemctl is-active --quiet "$DISPLAY_MANAGER"; then
            display_manager_was_active=1
            systemctl stop "$DISPLAY_MANAGER"
        fi
        loginctl terminate-user "$HOST_USER" || true
        pkill -TERM -u "$HOST_UID" || true
        sleep 3
        pgrep -u "$HOST_UID" >/dev/null 2>&1 && pkill -KILL -u "$HOST_UID" || true

        local -a nvidia_nodes=()
        mapfile -t nvidia_nodes < <(compgen -G '/dev/nvidia*' || true)
        local attempt
        for ((attempt=0; attempt<20; attempt++)); do
            if ((${#nvidia_nodes[@]} == 0)) || ! fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
        if ((${#nvidia_nodes[@]} > 0)) && fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
            fuser -v "${nvidia_nodes[@]}" || true
            die "结束图形会话后 NVIDIA 设备仍被占用"
        fi

        local vtconsole
        for vtconsole in /sys/class/vtconsole/vtcon*; do
            [[ -r "$vtconsole/name" && -w "$vtconsole/bind" ]] || continue
            if grep -qi 'frame buffer' "$vtconsole/name" && [[ "$(<"$vtconsole/bind")" == "1" ]]; then
                vtconsoles+=("$(basename "$vtconsole")")
                printf '0' >"$vtconsole/bind"
            fi
        done

        local gpu_path="/sys/bus/pci/devices/$GPU_BDF"
        if [[ -L "$gpu_path/driver" ]]; then
            local driver
            driver="$(basename "$(readlink -f "$gpu_path/driver")")"
            [[ "$driver" == nvidia ]] || die "nvflash 前 GPU 驱动应为 nvidia，实际为 $driver"
            printf '%s' "$GPU_BDF" >"$gpu_path/driver/unbind"
        fi
        local module
        for module in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
            [[ ! -d "/sys/module/$module" ]] || modprobe -r "$module"
        done

        log "nvflash 检测到的 NVIDIA 显卡："
        "$nvflash_bin" --list
        log "从 nvflash adapter $nvflash_index 提取 VBIOS……"
        "$nvflash_bin" --index="$nvflash_index" --save "$temporary"
    ); then
        rm -f "$temporary"
        die "nvflash 自动释放/提取失败；宿主恢复流程已经执行。"
    fi
    [[ -s "$temporary" ]] || { rm -f "$temporary"; die "nvflash 生成了空 ROM。"; }
    install -o root -g root -m 0644 "$temporary" "$destination_raw"
    rm -f "$temporary"
    log "原始 VBIOS 已保留：$destination_raw"
    sha256sum "$destination_raw"
}

find_ovmf() {
    local code_candidates=(
        /usr/share/edk2/x64/OVMF_CODE.4m.fd
        /usr/share/edk2/ovmf/OVMF_CODE.fd
        /usr/share/OVMF/OVMF_CODE.fd
    )
    local vars_candidates=(
        /usr/share/edk2/x64/OVMF_VARS.4m.fd
        /usr/share/edk2/ovmf/OVMF_VARS.fd
        /usr/share/OVMF/OVMF_VARS.fd
    )
    OVMF_CODE=''
    OVMF_VARS=''
    local candidate
    for candidate in "${code_candidates[@]}"; do [[ -f "$candidate" ]] && { OVMF_CODE="$candidate"; break; }; done
    for candidate in "${vars_candidates[@]}"; do [[ -f "$candidate" ]] && { OVMF_VARS="$candidate"; break; }; done
    [[ -n "$OVMF_CODE" && -n "$OVMF_VARS" ]] || die "找不到非 Secure Boot OVMF CODE/VARS 固件。"
}

ensure_default_network() {
    if ! virsh -c qemu:///system net-info default >/dev/null 2>&1; then
        local template='/usr/share/libvirt/networks/default.xml'
        [[ -f "$template" ]] || die "libvirt 默认网络不存在，且找不到 $template"
        virsh -c qemu:///system net-define "$template"
    fi
    virsh -c qemu:///system net-autostart default
    if ! virsh -c qemu:///system net-info default | grep -q '^Active:.*yes'; then
        virsh -c qemu:///system net-start default
    fi
}

write_config() {
    local temporary
    temporary="$(mktemp /etc/single-gpu-vfio.conf.XXXXXX)"
    {
        printf '# Generated by single-gpu-vfio %s\n' "$VERSION"
        config_value VM_NAME "$VM_NAME"
        config_value HOST_USER "$HOST_USER"
        config_value HOST_UID "$HOST_UID"
        config_value DISPLAY_MANAGER "$DISPLAY_MANAGER"
        config_value GPU_SERVICES "$GPU_SERVICES"
        config_value GPU_BDF "$GPU_BDF"
        config_value AUDIO_BDF "$AUDIO_BDF"
        config_value USB_BDF "$USB_BDF"
        config_value GPU_HOST_DRIVER "$GPU_HOST_DRIVER"
        config_value AUDIO_HOST_MODULE "$AUDIO_HOST_MODULE"
        config_value USB_HOST_MODULE "$USB_HOST_MODULE"
        config_value ISO_PATH "$ISO_PATH"
        config_value RAW_ROM_PATH "$RAW_ROM_PATH"
        config_value ROM_PATH "$ROM_PATH"
        config_value DISK_PATH "$DISK_PATH"
        config_value OVMF_CODE "$OVMF_CODE"
        config_value OVMF_VARS "$OVMF_VARS"
    } >"$temporary"
    install -o root -g root -m 0600 "$temporary" "$CONFIG_FILE"
    rm -f "$temporary"
}

write_hook() {
    install -d -o root -g root -m 0755 "$(dirname "$HOOK_FILE")"
    local temporary
    temporary="$(mktemp /etc/libvirt/hooks/qemu.d/.single-gpu-vfio.XXXXXX)"
    cat >"$temporary" <<EOF
#!/usr/bin/env bash
exec "$INSTALLED_TOOL" hook "\$@"
EOF
    install -o root -g root -m 0755 "$temporary" "$HOOK_FILE"
    rm -f "$temporary"
}

create_domain_xml() {
    local output="$1"
    local gpu_source audio_source usb_source
    gpu_source="$(pci_xml_address "$GPU_BDF")"
    audio_source="$(pci_xml_address "$AUDIO_BDF")"
    usb_source="$(pci_xml_address "$USB_BDF")"

    local vm_xml iso_xml disk_xml rom_xml code_xml vars_xml
    vm_xml="$(xml_escape "$VM_NAME")"
    iso_xml="$(xml_escape "$ISO_PATH")"
    disk_xml="$(xml_escape "$DISK_PATH")"
    rom_xml="$(xml_escape "$ROM_PATH")"
    code_xml="$(xml_escape "$OVMF_CODE")"
    vars_xml="$(xml_escape "$OVMF_VARS")"

    cat >"$output" <<EOF
<domain type="kvm">
  <name>$vm_xml</name>
  <title>NVIDIA single-GPU passthrough</title>
  <description>Starting this guest terminates the host graphical session and passes through its only GPU.</description>
  <memory unit="MiB">$MEMORY_MIB</memory>
  <currentMemory unit="MiB">$MEMORY_MIB</currentMemory>
  <vcpu placement="static">$VCPUS</vcpu>
  <os>
    <type arch="x86_64" machine="q35">hvm</type>
    <loader readonly="yes" secure="no" type="pflash">$code_xml</loader>
    <nvram template="$vars_xml">/var/lib/libvirt/qemu/nvram/${vm_xml}_VARS.fd</nvram>
    <boot dev="cdrom"/>
    <boot dev="hd"/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode="host-passthrough" check="none" migratable="on"/>
  <clock offset="utc">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="pit" tickpolicy="delay"/>
    <timer name="hpet" present="no"/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled="no"/>
    <suspend-to-disk enabled="no"/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" discard="unmap"/>
      <source file="$disk_xml"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <source file="$iso_xml"/>
      <target dev="sda" bus="sata"/>
      <readonly/>
    </disk>
    <controller type="usb" model="qemu-xhci" ports="15"/>
    <controller type="pci" model="pcie-root"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <interface type="network">
      <source network="default"/>
      <model type="virtio"/>
    </interface>
    <audio id="1" type="none"/>
    <video>
      <model type="none"/>
    </video>
    <console type="pty"/>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <driver name="vfio"/>
      <source>$gpu_source</source>
      <rom bar="on" file="$rom_xml"/>
      <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x0" multifunction="on"/>
    </hostdev>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <driver name="vfio"/>
      <source>$audio_source</source>
      <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x1"/>
    </hostdev>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <driver name="vfio"/>
      <source>$usb_source</source>
    </hostdev>
    <memballoon model="virtio"/>
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF
}

runtime_preflight() {
    load_config
    iommu_active || die "当前内核没有可用的 IOMMU 分组；检查 BIOS 与 GRUB，并重启。"
    [[ -f "$ROM_PATH" ]] || die "ROM 丢失：$ROM_PATH"
    [[ -f "$DISK_PATH" ]] || die "虚拟磁盘丢失：$DISK_PATH"
    local bdf
    for bdf in "$GPU_BDF" "$AUDIO_BDF" "$USB_BDF"; do
        [[ -e "/sys/bus/pci/devices/$bdf" ]] || die "PCI 设备不存在：$bdf"
        [[ -L "/sys/bus/pci/devices/$bdf/iommu_group" ]] || die "PCI 设备没有 IOMMU 分组：$bdf"
    done
    virsh -c qemu:///system dominfo "$VM_NAME" >/dev/null || die "libvirt 域不存在：$VM_NAME"
}

domain_is_off() {
    [[ "$(virsh -c qemu:///system domstate "$VM_NAME")" == "shut off" ]]
}

hook_prepare() (
    set -Eeuo pipefail
    load_config
    local state log_file
    state="$(state_dir)"
    log_file="$(hook_log_file)"
    mkdir -p "$state" "$(dirname "$log_file")"
    exec >>"$log_file" 2>&1
    local log_prefix='prepare'
    hlog() { printf '[%s] %s: %s\n' "$(date --iso-8601=seconds)" "$log_prefix" "$*"; }
    recover_on_error() {
        local rc=$?
        trap - EXIT
        if (( rc != 0 )); then
            hlog "hand-off failed (status $rc); restoring host graphics"
            hook_release || true
        fi
        exit "$rc"
    }
    trap recover_on_error EXIT

    hlog "beginning hand-off of $GPU_BDF"
    printf '%s\n' preparing >"$state/status"
    : >"$state/vtconsoles"
    : >"$state/services"
    rm -f "$state/display-manager-was-active"

    local service
    for service in $GPU_SERVICES; do
        [[ -n "$service" ]] || continue
        if systemctl is-active --quiet "$service"; then
            printf '%s\n' "$service" >>"$state/services"
            systemctl stop "$service"
            hlog "stopped $service"
        fi
    done

    if systemctl is-active --quiet "$DISPLAY_MANAGER"; then
        touch "$state/display-manager-was-active"
        systemctl stop "$DISPLAY_MANAGER"
        hlog "stopped $DISPLAY_MANAGER"
    fi

    loginctl terminate-user "$HOST_USER" || true
    pkill -TERM -u "$HOST_UID" || true
    hlog "requested termination of user $HOST_USER (uid $HOST_UID)"
    sleep 3
    if pgrep -u "$HOST_UID" >/dev/null 2>&1; then
        pkill -KILL -u "$HOST_UID" || true
        hlog "force-killed remaining uid $HOST_UID processes"
    fi

    local -a nvidia_nodes=()
    mapfile -t nvidia_nodes < <(compgen -G '/dev/nvidia*' || true)
    local attempt
    for ((attempt=0; attempt<20; attempt++)); do
        if ((${#nvidia_nodes[@]} == 0)) || ! fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
    if ((${#nvidia_nodes[@]} > 0)) && fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
        hlog "GPU device nodes remain in use; refusing unsafe detach"
        fuser -v "${nvidia_nodes[@]}" || true
        exit 1
    fi

    local vtconsole
    for vtconsole in /sys/class/vtconsole/vtcon*; do
        [[ -r "$vtconsole/name" && -w "$vtconsole/bind" ]] || continue
        if grep -qi 'frame buffer' "$vtconsole/name" && [[ "$(<"$vtconsole/bind")" == "1" ]]; then
            basename "$vtconsole" >>"$state/vtconsoles"
            printf '0' >"$vtconsole/bind"
        fi
    done

    local gpu_device="/sys/bus/pci/devices/$GPU_BDF"
    if [[ -L "$gpu_device/driver" ]]; then
        local driver
        driver="$(basename "$(readlink -f "$gpu_device/driver")")"
        [[ "$driver" == "$GPU_HOST_DRIVER" ]] || die "GPU 当前驱动为 $driver，预期 $GPU_HOST_DRIVER"
        printf '%s' "$GPU_BDF" >"$gpu_device/driver/unbind"
        hlog "unbound $GPU_BDF from $driver"
    fi
    [[ ! -L "$gpu_device/driver" ]] || die "GPU 在 unbind 后仍绑定驱动"

    local module
    for module in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        if [[ -d "/sys/module/$module" ]]; then
            modprobe -r "$module"
            hlog "unloaded $module"
        fi
    done
    modprobe vfio-pci
    printf '%s\n' ready >"$state/status"
    hlog "host NVIDIA stack released; libvirt may attach devices"
    trap - EXIT
)

hook_release() (
    set -Eeuo pipefail
    load_config
    local state log_file
    state="$(state_dir)"
    log_file="$(hook_log_file)"
    mkdir -p "$state" "$(dirname "$log_file")"
    exec >>"$log_file" 2>&1
    hlog() { printf '[%s] release: %s\n' "$(date --iso-8601=seconds)" "$*"; }

    exec 9>"$state/release.lock"
    flock 9
    if [[ -r "$state/status" && "$(<"$state/status")" == "recovered" ]]; then
        hlog "host graphics already recovered; ignoring duplicate release"
        exit 0
    fi
    hlog "recovering host graphics"
    printf '%s\n' recovering >"$state/status"

    modprobe nvidia
    modprobe nvidia_modeset
    modprobe nvidia_uvm
    modprobe nvidia_drm
    modprobe "$AUDIO_HOST_MODULE"
    modprobe "$USB_HOST_MODULE"

    local device
    for device in "$GPU_BDF" "$AUDIO_BDF" "$USB_BDF"; do
        if [[ -e "/sys/bus/pci/devices/$device" && ! -L "/sys/bus/pci/devices/$device/driver" ]]; then
            printf '%s' "$device" >/sys/bus/pci/drivers_probe || true
        fi
    done

    if [[ -s "$state/vtconsoles" ]]; then
        local vtconsole
        while read -r vtconsole; do
            [[ -w "/sys/class/vtconsole/$vtconsole/bind" ]] && \
                printf '1' >"/sys/class/vtconsole/$vtconsole/bind" || true
        done <"$state/vtconsoles"
    fi

    if [[ -s "$state/services" ]]; then
        local service
        while read -r service; do systemctl start "$service" || true; done <"$state/services"
    fi
    if [[ -e "$state/display-manager-was-active" ]]; then
        systemctl start "$DISPLAY_MANAGER"
    fi
    printf '%s\n' recovered >"$state/status"
    hlog "host graphics recovered"
)

cmd_hook() {
    local guest="${1:-}" operation="${2:-}" phase="${3:-}"
    local xml_file
    xml_file="$(mktemp /run/libvirt-single-gpu-hook.XXXXXX)"
    trap 'rm -f "$xml_file"' EXIT
    cat >"$xml_file"
    if [[ -r "$CONFIG_FILE" ]]; then
        load_config
        if [[ "$guest" == "$VM_NAME" && "$operation" == "prepare" && "$phase" == "begin" ]]; then
            hook_prepare
        elif [[ "$guest" == "$VM_NAME" && "$operation" == "release" && "$phase" == "end" ]]; then
            hook_release
        fi
    fi
    cat "$xml_file"
    rm -f "$xml_file"
    trap - EXIT
}

cmd_recover() {
    require_root
    load_config
    if virsh -c qemu:///system domstate "$VM_NAME" 2>/dev/null | grep -qiE 'running|paused|in shutdown|pmsuspended'; then
        die "$VM_NAME 仍在运行；先 shutdown 或 force-stop。"
    fi

    local device path driver
    for device in "$GPU_BDF" "$AUDIO_BDF" "$USB_BDF"; do
        path="/sys/bus/pci/devices/$device"
        [[ -e "$path" ]] || continue
        driver="$(pci_driver "$device")"
        if [[ "$driver" == "vfio-pci" ]]; then
            printf '%s' "$device" >/sys/bus/pci/drivers/vfio-pci/unbind
        fi
        printf '%s' '' >"$path/driver_override"
    done

    modprobe nvidia
    modprobe nvidia_modeset
    modprobe nvidia_uvm
    modprobe nvidia_drm
    modprobe "$AUDIO_HOST_MODULE"
    modprobe "$USB_HOST_MODULE"
    for device in "$GPU_BDF" "$AUDIO_BDF" "$USB_BDF"; do
        [[ -e "/sys/bus/pci/devices/$device" && ! -L "/sys/bus/pci/devices/$device/driver" ]] && \
            printf '%s' "$device" >/sys/bus/pci/drivers_probe || true
    done

    local vtconsole
    for vtconsole in /sys/class/vtconsole/vtcon*; do
        [[ -w "$vtconsole/bind" && -r "$vtconsole/name" ]] || continue
        grep -qi 'frame buffer' "$vtconsole/name" && printf '1' >"$vtconsole/bind" || true
    done
    local service
    for service in $GPU_SERVICES; do
        systemctl is-enabled --quiet "$service" 2>/dev/null && systemctl start "$service" || true
    done
    systemctl start "$DISPLAY_MANAGER"
    log "已请求恢复宿主显卡并启动 $DISPLAY_MANAGER。"
}

cmd_check() {
    runtime_preflight
    log "虚拟机：$VM_NAME ($(virsh -c qemu:///system domstate "$VM_NAME"))"
    printf 'IOMMU/PCI：\n'
    show_iommu_group "$GPU_BDF" || true
    show_iommu_group "$AUDIO_BDF" || true
    show_iommu_group "$USB_BDF" || true
    printf '\n驱动：\n'
    printf '  %-14s %s\n' "$GPU_BDF" "$(pci_driver "$GPU_BDF")"
    printf '  %-14s %s\n' "$AUDIO_BDF" "$(pci_driver "$AUDIO_BDF")"
    printf '  %-14s %s\n' "$USB_BDF" "$(pci_driver "$USB_BDF")"
    printf '\n文件：\n'
    stat -c '  %A %U:%G %s %n' "$ROM_PATH" "$DISK_PATH" "$ISO_PATH" 2>/dev/null || true
    qemu-img check "$DISK_PATH"

    local native
    native="$(mktemp /tmp/single-gpu-vfio-native.XXXXXX)"
    virsh -c qemu:///system domxml-to-native qemu-argv \
        <(virsh -c qemu:///system dumpxml "$VM_NAME") >"$native"
    if rg -q 'display["=]|x-vga|OVMF_CODE\.secboot' "$native"; then
        rg 'display["=]|x-vga|OVMF_CODE\.secboot' "$native" >&2
        rm -f "$native"
        die "发现不应存在的 vGPU/x-vga/Secure Boot 参数。"
    fi
    rm -f "$native"
    log "检查通过。"
}

cmd_test() {
    require_root
    runtime_preflight
    domain_is_off || die "$VM_NAME 当前不是 shut off。"
    local timeout_seconds="${1:-90}"
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds >= 30 && timeout_seconds <= 600 )) || \
        die "测试秒数必须在 30–600 之间。"
    local run_id safety_unit launch_unit
    run_id="$(date +%s)-$$"
    safety_unit="single-gpu-vfio-safety-$run_id"
    launch_unit="single-gpu-vfio-test-$run_id"
    systemd-run --quiet --collect --unit="$safety_unit" \
        --on-active="${timeout_seconds}s" --timer-property=AccuracySec=1s \
        /usr/bin/bash -c "/usr/bin/virsh -c qemu:///system destroy '$VM_NAME' >/dev/null 2>&1 || true; '$INSTALLED_TOOL' recover || true"
    log "启动 $VM_NAME；已设置 ${timeout_seconds} 秒后强制停止并恢复宿主。"
    systemd-run --collect --unit="$launch_unit" \
        /usr/bin/virsh -c qemu:///system start --reset-nvram "$VM_NAME"
}

cmd_start() {
    require_root
    runtime_preflight
    domain_is_off || die "$VM_NAME 当前不是 shut off。"
    local unit="single-gpu-vfio-start-$(date +%s)-$$"
    log "启动 $VM_NAME；当前图形会话将结束。"
    systemd-run --collect --unit="$unit" \
        /usr/bin/virsh -c qemu:///system start "$VM_NAME"
}

cmd_shutdown() {
    require_root
    load_config
    virsh -c qemu:///system shutdown "$VM_NAME"
    log "已向 $VM_NAME 发送 ACPI 关机请求。"
}

cmd_force_stop() {
    require_root
    load_config
    warn "即将强制关闭 $VM_NAME，效果相当于拔掉虚拟机电源。"
    confirm "确定强制关闭吗？"
    virsh -c qemu:///system destroy "$VM_NAME" || true
    sleep 2
    cmd_recover
}

cmd_status() {
    load_config
    printf 'VM: %s\n' "$VM_NAME"
    virsh -c qemu:///system domstate "$VM_NAME" 2>/dev/null || true
    printf '\nPCI drivers:\n'
    local device
    for device in "$GPU_BDF" "$AUDIO_BDF" "$USB_BDF"; do
        printf '  %-14s %s\n' "$device" "$(pci_driver "$device")"
    done
    printf '\nTransient safety timers:\n'
    systemctl list-timers --all 'single-gpu-vfio-*' --no-pager --plain || true
    printf '\nRecent hook log:\n'
    tail -n 60 "$(hook_log_file)" 2>/dev/null || true
}

cmd_eject_iso() {
    require_root
    load_config
    domain_is_off || die "请先关闭 $VM_NAME。"
    virsh -c qemu:///system change-media "$VM_NAME" sda --eject --config
    log "已弹出安装 ISO；下次将从虚拟硬盘启动。"
}

cmd_remove() {
    require_root
    load_config
    domain_is_off || die "请先关闭 $VM_NAME。"
    warn "将移除 libvirt 定义、hook、配置和已安装的管理工具。"
    warn "不会删除磁盘 $DISK_PATH，也不会删除 ROM $ROM_PATH。"
    confirm "确定移除吗？"
    virsh -c qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || \
        virsh -c qemu:///system undefine "$VM_NAME" 2>/dev/null || true
    rm -f "$HOOK_FILE" "$CONFIG_FILE"
    log "已移除配置。IOMMU 启动参数、软件包、磁盘和 ROM 保留。"
    rm -f "$INSTALLED_TOOL"
}

cmd_install() {
    require_root
    local -a original_install_args=("$@")
    VM_NAME='single-gpu-vm'
    ISO_PATH=''
    ROM_SOURCE=''
    NVFLASH_BIN=''
    NVFLASH_INDEX='0'
    NVFLASH_INDEX_SET=0
    GPU_BDF=''
    AUDIO_BDF=''
    USB_BDF=''
    DISK_PATH=''
    DISK_SIZE='40G'
    MEMORY_MIB='8192'
    VCPUS='4'
    HOST_USER="${SUDO_USER:-}"
    DISPLAY_MANAGER=''
    GPU_SERVICES='auto'
    ASSUME_YES=0
    ALLOW_EXISTING_HOOKS=0
    SKIP_PACKAGES=0

    while (($#)); do
        case "$1" in
            --vm-name) VM_NAME="${2:?}"; shift 2 ;;
            --iso) ISO_PATH="${2:?}"; shift 2 ;;
            --rom) ROM_SOURCE="${2:?}"; shift 2 ;;
            --nvflash) NVFLASH_BIN="${2:?}"; shift 2 ;;
            --nvflash-index) NVFLASH_INDEX="${2:?}"; NVFLASH_INDEX_SET=1; shift 2 ;;
            --gpu) GPU_BDF="${2:?}"; shift 2 ;;
            --audio) AUDIO_BDF="${2:?}"; shift 2 ;;
            --usb) USB_BDF="${2:?}"; shift 2 ;;
            --disk) DISK_PATH="${2:?}"; shift 2 ;;
            --disk-size) DISK_SIZE="${2:?}"; shift 2 ;;
            --memory) MEMORY_MIB="${2:?}"; shift 2 ;;
            --vcpus) VCPUS="${2:?}"; shift 2 ;;
            --user) HOST_USER="${2:?}"; shift 2 ;;
            --display-manager) DISPLAY_MANAGER="${2:?}"; shift 2 ;;
            --gpu-services) GPU_SERVICES="${2:?}"; shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            --allow-existing-hooks) ALLOW_EXISTING_HOOKS=1; shift ;;
            --skip-packages) SKIP_PACKAGES=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知 install 参数：$1" ;;
        esac
    done

    [[ "$VM_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "VM 名称只能包含字母、数字、点、下划线和连字符。"
    [[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || die "必须通过 --iso 指定存在的 ISO。"
    [[ -z "$ROM_SOURCE" || -f "$ROM_SOURCE" ]] || die "--rom 指定的文件不存在：$ROM_SOURCE"
    [[ -n "$USB_BDF" ]] || die "必须通过 --usb 指定要整体直通的 USB 控制器。"
    [[ -n "$HOST_USER" && "$HOST_USER" != root ]] || die "无法确定普通图形用户，请使用 --user。"
    id "$HOST_USER" >/dev/null 2>&1 || die "用户不存在：$HOST_USER"
    HOST_UID="$(id -u "$HOST_USER")"
    (( HOST_UID > 0 )) || die "拒绝终止 root 会话。"
    [[ "$MEMORY_MIB" =~ ^[0-9]+$ ]] && (( MEMORY_MIB >= 2048 )) || die "--memory 至少为 2048 MiB。"
    [[ "$VCPUS" =~ ^[0-9]+$ ]] && (( VCPUS >= 1 )) || die "--vcpus 必须是正整数。"
    [[ "$DISK_SIZE" =~ ^[1-9][0-9]*[GMTP]$ ]] || die "--disk-size 示例：40G。"

    if (( ! SKIP_PACKAGES )); then install_packages; fi
    require_command lspci
    require_command virsh
    require_command qemu-img
    require_command virt-xml-validate
    require_command systemd-run

    GPU_BDF="${GPU_BDF:-$(detect_gpu)}"
    [[ -n "$GPU_BDF" ]] || die "未检测到 NVIDIA VGA/3D 设备，请使用 --gpu。"
    GPU_BDF="$(normalize_bdf "$GPU_BDF")"
    AUDIO_BDF="${AUDIO_BDF:-$(detect_gpu_audio "$GPU_BDF")}"
    [[ -n "$AUDIO_BDF" ]] || die "未找到同槽位 NVIDIA 音频设备，请使用 --audio。"
    AUDIO_BDF="$(normalize_bdf "$AUDIO_BDF")"
    USB_BDF="$(normalize_bdf "$USB_BDF")"

    if [[ -z "$ROM_SOURCE" ]]; then
        if [[ -z "$NVFLASH_BIN" ]]; then
            NVFLASH_BIN="$(command -v nvflash 2>/dev/null || command -v nvflash_linux 2>/dev/null || true)"
        fi
        if [[ -z "$NVFLASH_BIN" ]]; then
            local aur_helper=''
            aur_helper="$(command -v yay 2>/dev/null || command -v paru 2>/dev/null || true)"
            if [[ -n "$aur_helper" ]]; then
                warn "nvflash 不在官方 Arch 仓库中；将通过 $(basename "$aur_helper") 构建并安装 AUR 包。"
                confirm "允许安装 AUR 包 nvflash 吗？"
                sudo -H -u "$HOST_USER" "$aur_helper" -S --needed nvflash
                NVFLASH_BIN="$(command -v nvflash 2>/dev/null || true)"
            fi
        fi
        [[ -n "$NVFLASH_BIN" ]] || die "未找到 nvflash。请先从 AUR 安装 nvflash、通过 --nvflash 指定程序，或使用 --rom。"
        NVFLASH_BIN="$(readlink -f "$NVFLASH_BIN")"
        local nvidia_gpu_count
        nvidia_gpu_count="$(lspci -Dnn | awk '/NVIDIA/ && (/VGA compatible controller/ || /3D controller/) {count++} END {print count+0}')"
        if (( nvidia_gpu_count > 1 && ! NVFLASH_INDEX_SET )); then
            die "检测到多块 NVIDIA GPU；请用 nvflash --list 核对后指定 --nvflash-index。"
        fi
    fi

    local bdf
    for bdf in "$GPU_BDF" "$AUDIO_BDF" "$USB_BDF"; do
        [[ -e "/sys/bus/pci/devices/$bdf" ]] || die "PCI 设备不存在：$bdf"
    done
    [[ "$(pci_class "$GPU_BDF")" == 0x0300* || "$(pci_class "$GPU_BDF")" == 0x0302* ]] || \
        die "$GPU_BDF 不是 VGA/3D 控制器。"
    [[ "$(pci_class "$AUDIO_BDF")" == 0x0403* ]] || die "$AUDIO_BDF 不是 HDA 音频设备。"
    [[ "$(pci_class "$USB_BDF")" == 0x0c03* ]] || die "$USB_BDF 不是 USB 控制器。"

    GPU_HOST_DRIVER="$(pci_driver "$GPU_BDF")"
    [[ "$GPU_HOST_DRIVER" == nvidia ]] || die "GPU 必须由 nvidia 驱动，当前为 $GPU_HOST_DRIVER。"
    AUDIO_HOST_MODULE='snd_hda_intel'
    USB_HOST_MODULE='xhci_pci'
    DISPLAY_MANAGER="${DISPLAY_MANAGER:-$(detect_display_manager)}"
    [[ "$DISPLAY_MANAGER" == *.service ]] || DISPLAY_MANAGER="${DISPLAY_MANAGER}.service"
    if [[ "$GPU_SERVICES" == auto ]]; then
        GPU_SERVICES=''
        systemctl list-unit-files lactd.service --no-legend 2>/dev/null | grep -q . && GPU_SERVICES='lactd.service'
    else
        GPU_SERVICES="${GPU_SERVICES//,/ }"
    fi
    for service in $GPU_SERVICES; do
        [[ "$service" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || die "无效服务名：$service"
    done

    if (( ! ALLOW_EXISTING_HOOKS )); then
        local existing=''
        existing="$(rg -l -i 'vfio|nvidia.*unbind|nodedev-detach' /etc/libvirt/hooks 2>/dev/null | \
            grep -vFx "$HOOK_FILE" || true)"
        [[ -z "$existing" ]] || die "发现可能冲突的现有 VFIO hook：\n$existing\n确认兼容后使用 --allow-existing-hooks。"
    fi

    if ! grep -qwE 'intel_iommu=on|amd_iommu=on' /proc/cmdline || ! grep -qw iommu=pt /proc/cmdline; then
        configure_grub_iommu
        warn "当前启动尚未使用新的 IOMMU 参数；完成安装后必须重启再运行 check/test。"
    fi

    if iommu_active; then
        printf '\n将要直通的 IOMMU 分组：\n'
        show_iommu_group "$GPU_BDF" || true
        show_iommu_group "$AUDIO_BDF" || true
        show_iommu_group "$USB_BDF" || true
        confirm "确认这些分组中的全部设备都可以交给虚拟机吗？"
    else
        warn "IOMMU 当前未激活，无法验证分组；重启后必须运行 check。"
    fi

    if [[ -z "$ROM_SOURCE" && "${SGVFIO_INSTALL_WORKER:-0}" != "1" ]]; then
        local self_path install_unit
        self_path="$(readlink -f "$0")"
        install -o root -g root -m 0755 "$self_path" "$INSTALLED_TOOL"
        install_unit="single-gpu-vfio-install-$(date +%s)-$$"
        log "VBIOS 自动提取需要注销图形会话；配置将由 systemd 任务继续。"
        log "恢复登录后可查看：sudo journalctl -u $install_unit"
        systemd-run --collect --unit="$install_unit" --setenv=SGVFIO_INSTALL_WORKER=1 \
            "$INSTALLED_TOOL" install "${original_install_args[@]}" \
            --user "$HOST_USER" --yes --skip-packages
        return
    fi

    DISK_PATH="${DISK_PATH:-/var/lib/libvirt/images/${VM_NAME}.qcow2}"
    [[ "$ISO_PATH" == /* && "$DISK_PATH" == /* ]] || die "ISO 和磁盘必须使用绝对路径。"
    [[ -z "$ROM_SOURCE" || "$ROM_SOURCE" == /* ]] || die "--rom 必须使用绝对路径。"
    install -d -m 0755 "$(dirname "$DISK_PATH")"
    if [[ ! -e "$DISK_PATH" ]]; then
        qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
    else
        qemu-img check "$DISK_PATH"
        warn "保留已有虚拟磁盘：$DISK_PATH"
    fi

    RAW_ROM_PATH="/var/lib/libvirt/vbios/${VM_NAME}.raw.rom"
    ROM_PATH="/var/lib/libvirt/vbios/${VM_NAME}.rom"
    if [[ -n "$ROM_SOURCE" ]]; then
        install -d -m 0755 "$(dirname "$RAW_ROM_PATH")"
        install -o root -g root -m 0644 "$ROM_SOURCE" "$RAW_ROM_PATH"
        log "原始 VBIOS 已保留：$RAW_ROM_PATH"
    else
        extract_rom_nvflash "$NVFLASH_BIN" "$NVFLASH_INDEX" "$RAW_ROM_PATH"
    fi
    prepare_rom "$RAW_ROM_PATH" "$ROM_PATH"
    find_ovmf
    ensure_default_network

    install -d -m 0755 "$BACKUP_DIR"
    if virsh -c qemu:///system dominfo "$VM_NAME" >/dev/null 2>&1; then
        domain_state="$(virsh -c qemu:///system domstate "$VM_NAME")"
        [[ "$domain_state" == "shut off" ]] || die "已有域 $VM_NAME 正在运行。"
        virsh -c qemu:///system dumpxml "$VM_NAME" >"$BACKUP_DIR/${VM_NAME}.$(date +%Y%m%d-%H%M%S).xml"
        warn "将更新已有 libvirt 域：$VM_NAME"
    fi

    local self_path
    self_path="$(readlink -f "$0")"
    if [[ "$self_path" != "$INSTALLED_TOOL" ]]; then
        install -o root -g root -m 0755 "$self_path" "$INSTALLED_TOOL"
    fi
    write_config
    write_hook

    local xml_file native_file
    xml_file="$(mktemp /tmp/single-gpu-vfio-domain.XXXXXX.xml)"
    native_file="$(mktemp /tmp/single-gpu-vfio-native.XXXXXX)"
    create_domain_xml "$xml_file"
    virt-xml-validate "$xml_file"
    virsh -c qemu:///system domxml-to-native qemu-argv "$xml_file" >"$native_file"
    if rg -q 'display["=]|x-vga|OVMF_CODE\.secboot' "$native_file"; then
        rm -f "$xml_file" "$native_file"
        die "生成的 QEMU 参数包含禁止的 display/x-vga/Secure Boot 配置。"
    fi
    virsh -c qemu:///system define "$xml_file"
    rm -f "$xml_file" "$native_file"
    virsh -c qemu:///system autostart "$VM_NAME" --disable >/dev/null 2>&1 || true

    usermod -a -G libvirt,kvm "$HOST_USER"
    systemctl restart libvirtd.service

    log "安装完成。"
    printf '\n下一步：\n'
    if iommu_active; then
        printf '  sudo %s check\n  sudo %s test 90\n' "$INSTALLED_TOOL" "$INSTALLED_TOOL"
    else
        printf '  1. 重启宿主\n  2. sudo %s check\n  3. sudo %s test 90\n' "$INSTALLED_TOOL" "$INSTALLED_TOOL"
    fi
    printf '\n正常启动：sudo %s start\n' "$INSTALLED_TOOL"
}

main() {
    local command="${1:-help}"
    shift || true
    case "$command" in
        help|-h|--help) usage ;;
        version|--version) printf '%s\n' "$VERSION" ;;
        detect) show_detection ;;
        install) cmd_install "$@" ;;
        check) cmd_check "$@" ;;
        test) cmd_test "$@" ;;
        start) cmd_start "$@" ;;
        shutdown) cmd_shutdown "$@" ;;
        force-stop) cmd_force_stop "$@" ;;
        recover) cmd_recover "$@" ;;
        eject-iso) cmd_eject_iso "$@" ;;
        status) cmd_status "$@" ;;
        remove) cmd_remove "$@" ;;
        hook) cmd_hook "$@" ;;
        *) die "未知命令：$command（运行 $0 help 查看帮助）" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
