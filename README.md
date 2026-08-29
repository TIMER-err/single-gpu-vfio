# single-gpu-vfio

> **个人自用配置。** 这是为我自己的 Arch/EndeavourOS 主机整理的 NVIDIA 单显卡 KVM/VFIO 工具，不是通用安装器，也不保证适用于其他硬件。显卡直通、PCI 解绑和驱动重载均有造成黑屏、系统失去响应或数据损坏的风险；使用前请创建快照并保存工作。

这个单文件脚本把一次已经实际验证成功的配置流程整理为可重复执行的工具，目标环境是：

- Arch Linux / EndeavourOS；
- GRUB（包括 Legacy BIOS 启动的宿主）；
- NVIDIA 闭源驱动；
- 单显卡宿主，启动虚拟机时结束当前图形会话；
- OVMF/Q35 来宾；
- 可选将整块 USB 控制器交给来宾。

当前验证环境：GTX 1050、NVIDIA 580 驱动、KDE Plasma Wayland、greetd、Linux Zen 7.1、Intel IOMMU。主机使用 Legacy GRUB，来宾使用非 Secure Boot OVMF。

## 功能

- 安装 QEMU、libvirt、OVMF、virt-manager 等依赖；
- 为 Intel/AMD CPU 配置 GRUB IOMMU 参数；
- 检查 PCI 地址、驱动和 IOMMU 分组；
- 通过 `nvflash` 自动提取 VBIOS；
- 提取时由 systemd 任务安全结束图形会话、卸载 NVIDIA 驱动并恢复宿主；
- 验证 ROM 的 `55 aa`、`PCIR`、PCI ID 与 EFI GOP，并自动去掉 NVIDIA 容器头；
- 分别保留原始 ROM 和处理后的 ROM；
- 创建 qcow2、libvirt NAT 网络和最小化 Q35/OVMF 虚拟机；
- 安装单显卡释放/恢复 hook；
- 提供带自动回退的首次测试、正常启动、关机、强制停止和紧急恢复命令。

## 使用

先查看自动检测结果：

```bash
./single-gpu-vfio.sh detect
```

示例安装：

```bash
sudo ./single-gpu-vfio.sh install \
  --vm-name omarchy-vfio \
  --iso /absolute/path/to/installer.iso \
  --gpu 0000:01:00.0 \
  --audio 0000:01:00.1 \
  --usb 0000:00:14.0 \
  --disk /absolute/path/to/guest.qcow2 \
  --disk-size 40G \
  --memory 8192 \
  --vcpus 4
```

省略 `--rom` 时，脚本会寻找 `nvflash`；若尚未安装且系统中有 `yay` 或 `paru`，确认后会从 AUR 安装。随后脚本会注销一次图形会话，在 root 的 systemd 临时任务中完成驱动释放、VBIOS 提取、宿主恢复和剩余配置。

如果已准备好 ROM，也可以添加：

```bash
--rom /absolute/path/to/dumped.rom
```

首次配置若修改了 GRUB，请先重启。之后运行：

```bash
sudo single-gpu-vfio check
sudo single-gpu-vfio test 90
sudo single-gpu-vfio start
```

`test` 会在指定秒数后强制停止来宾并恢复宿主，仅用于确认直通画面。正式使用时应在来宾系统内部正常关机；`Ctrl+Alt+Delete` 通常只是重启来宾。

安装系统完成并关闭虚拟机后，可弹出 ISO：

```bash
sudo single-gpu-vfio eject-iso
```

查看所有命令：

```bash
./single-gpu-vfio.sh help
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

## 范围说明

脚本不会把 GPU 永久绑定给 `vfio-pci`，宿主启动后仍使用 NVIDIA 驱动。它也不会自动判断任意 IOMMU 分组是否安全；安装时必须人工确认组内的全部设备都可以交给来宾。

脚本目前不面向 AMD GPU、systemd-boot、双 GPU、笔记本混合显卡、Looking Glass 或 SR-IOV/vGPU 场景。
