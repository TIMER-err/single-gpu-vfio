# single-gpu-vfio

> **个人自用配置。** 这是为我自己的 Arch/EndeavourOS 主机整理的 NVIDIA 单显卡 KVM/VFIO 工具，不是通用安装器，也不保证适用于其他硬件。显卡直通、PCI 解绑和驱动重载均有造成黑屏、系统失去响应或数据损坏的风险；使用前请创建快照并保存工作。

这个脚本把直通配置拆成三个相互独立的阶段：配置宿主环境、在 TTY 中提取 VBIOS、创建虚拟机。创建虚拟机时不会再次安装软件、修改 GRUB 或提取 ROM。

目标环境：

- Arch Linux / EndeavourOS；
- GRUB（包括 Legacy BIOS 启动的宿主）；
- NVIDIA 闭源驱动；
- 单显卡宿主，启动虚拟机时结束当前图形会话；
- OVMF/Q35 来宾；
- 可选将整块 USB 控制器交给来宾。

当前验证环境：GTX 1050、NVIDIA 580 驱动、KDE Plasma Wayland、greetd、Linux Zen 7.1、Intel IOMMU。主机使用 Legacy GRUB，来宾使用非 Secure Boot OVMF。

脚本自身的提示和错误信息全部使用 ASCII 英文，以便在没有中文字库的 Linux TTY 中正常显示。

## 功能

- 安装 QEMU、libvirt、OVMF、virt-manager 等依赖；
- 为 Intel/AMD CPU 配置 GRUB IOMMU 参数；
- 检查 PCI 地址、设备类别、驱动和 IOMMU 分组；
- 在真实 Linux TTY 中卸载 NVIDIA 驱动并调用 `nvflash` 提取 VBIOS；
- 使用 `nvflash --verify` 将保存的 ROM 与显卡进行校验；
- 验证 ROM 的 `55 aa`、`PCIR`、PCI ID 与 EFI GOP，并自动去掉 NVIDIA 容器头；
- 分别保留原始 ROM 和处理后的 ROM，并打印 SHA-256；
- 创建 qcow2、libvirt NAT 网络和最小化 Q35/OVMF 虚拟机；
- 保留 NVIDIA HDMI/DP 音频直通，并可将主板模拟输出通过虚拟 Intel HDA/ALSA 提供给来宾；
- 安装单显卡释放/恢复 hook；
- 提供带自动回退的首次测试、正常启动、关机、强制停止和紧急恢复命令。

## 使用流程

先查看自动检测结果：

```bash
./single-gpu-vfio.sh detect
```

### 1. 配置宿主环境

这一步可以在 KDE/Plasma 的图形终端中运行：

```bash
sudo ./single-gpu-vfio.sh setup-host --user timer
```

它会安装依赖和 `nvflash`、配置 GRUB IOMMU、把用户加入 `libvirt`/`kvm` 组，并将工具安装为 `/usr/local/sbin/single-gpu-vfio`。

如果系统已经安装好依赖或 `nvflash`，可使用 `--skip-packages` 或 `--skip-nvflash`。如果脚本修改了 GRUB，在创建和启动虚拟机前必须重启。

### 2. 在 TTY 中提取并处理 VBIOS

先保存工作并**完全注销 Plasma/Hyprland**，按 `Ctrl+Alt+F3` 切换到真实 Linux TTY，然后登录并运行：

```bash
sudo single-gpu-vfio extract-rom \
  --gpu 0000:01:00.0 \
  --output /var/lib/libvirt/vbios/gtx1050.rom
```

脚本拒绝从 GUI 终端、SSH 或 `/dev/pts/*` 执行此命令。提取期间终端画面可能暂时变黑；不要强制断电。默认同时保存原始文件 `/var/lib/libvirt/vbios/gtx1050.raw.rom`。

如果有多张 NVIDIA 显卡，先在 TTY 中运行 `nvflash --list`，并明确添加 `--nvflash-index N`。此脚本的其余直通流程仍主要面向单显卡主机。

### 3. 创建虚拟机

如第 1 步修改了 GRUB，先重启。回到桌面后运行：

```bash
sudo single-gpu-vfio create-vm \
  --vm-name omarchy-vfio \
  --iso /absolute/path/to/omarchy.iso \
  --rom /var/lib/libvirt/vbios/gtx1050.rom \
  --gpu 0000:01:00.0 \
  --audio 0000:01:00.1 \
  --host-audio hw:PCH,0 \
  --usb 0000:00:14.0 \
  --disk /absolute/path/to/omarchy-vfio.qcow2 \
  --disk-size 40G \
  --memory 8192 \
  --vcpus 4 \
  --user timer
```

`create-vm` 会再次解析并验证 ROM，然后展示 GPU、显卡音频和 USB 控制器的 IOMMU 分组，得到确认后才生成虚拟机和 hook。已有虚拟磁盘不会被覆盖。

`--audio` 是随显卡一起直通的 NVIDIA HDMI/DP 音频。`--host-audio` 则用于宿主的主板模拟输出；默认值 `auto` 会选择第一块非 NVIDIA ALSA 播放设备。使用 `--host-audio none` 可以禁用虚拟声卡，只保留 HDMI/DP 音频。主板声卡若与 ISA、PMC、SMBus 等设备共用 IOMMU 组，不应直接进行 PCI 直通。

## 启动与关机

首次测试：

```bash
sudo single-gpu-vfio check
sudo single-gpu-vfio test 90
```

`test 90` 会启动虚拟机，并在 90 秒后强制停止来宾、尝试恢复宿主，适合确认直通画面。确认正常后使用：

```bash
sudo single-gpu-vfio start
```

`test` 和 `start` 都会结束当前图形会话，因此运行前必须保存工作。进入来宾后应从来宾系统内部正常关机；`Ctrl+Alt+Delete` 通常会重启来宾，并不等同于关机。也可以从宿主的 SSH/TTY 请求 ACPI 关机：

```bash
sudo single-gpu-vfio shutdown
```

安装系统完成并关闭虚拟机后，可弹出 ISO：

```bash
sudo single-gpu-vfio eject-iso
```

## 恢复

来宾已经停止但宿主图形没有恢复时，可从 SSH 或文本终端运行：

```bash
sudo single-gpu-vfio recover
```

只有来宾完全无响应时才使用：

```bash
sudo single-gpu-vfio force-stop
```

该操作相当于拔掉虚拟机电源。

查看状态和完整帮助：

```bash
sudo single-gpu-vfio status
single-gpu-vfio help
```

## ROM 校验说明

ROM 提取包含两类不同校验：

1. `nvflash --verify` 将刚保存的原始 ROM 与实际显卡固件进行硬件侧校验；
2. 脚本解析 PCI Option ROM 链，核对显卡 vendor/device ID，要求存在 EFI GOP，并只移除 ROM 前面的非固件容器数据。

脚本会打印原始 ROM 和处理后 ROM 的 SHA-256，便于归档与后续比对。由于去掉了容器头，两者哈希和文件大小可能不同，这是预期行为。

## 范围说明

脚本不会把 GPU 永久绑定给 `vfio-pci`，宿主启动后仍使用 NVIDIA 驱动。它也不会自动判断任意 IOMMU 分组是否安全；创建虚拟机时必须人工确认组内的全部设备都可以交给来宾。

脚本目前不面向 AMD GPU、systemd-boot、双 GPU、笔记本混合显卡、Looking Glass 或 SR-IOV/vGPU 场景。
