# sm8250-xiaomi-lmi-rootfs

Redmi K30 Pro / POCO F2 Pro（lmi，SM8250）主线 Linux rootfs 构建辅助仓库。

这个仓库保存 Ubuntu debug rootfs、Fedora/KDE rootfs、ext4 镜像和分区布局相关的脚本。项目原则是硬件支持优先放在内核、DTS、initramfs 和启动支持层中完成；rootfs 仓库只用于生成可测试的发行版系统和少量调试辅助文件。

## 当前用途

- 构建 Ubuntu arm64 debug rootfs。
- 构建或导入 Fedora KDE aarch64 rootfs。
- 生成 ext4 / sparse ext4 镜像。
- 计算 lmi 多系统分区布局，保留 debug rootfs 空间。
- 提供 debug rootfs 下的按键/背光调试辅助服务。
- 提供 Sahara/modem 诊断入口脚本，用于配合内核侧调制解调器 bring-up。

## 目录

```text
scripts/   rootfs 构建、导入、检查、镜像和分区布局脚本
files/     需要叠加进 debug/rootfs 的少量 lmi 调试文件
local/     本地环境、密钥、固件和授权配置，不提交
out/       rootfs、镜像、下载缓存和构建输出，不提交
```

公开仓库只包含脚本和小型调试辅助文件，不包含已经生成的 rootfs、Fedora 镜像下载、ext4 镜像、设备私有文件或 SSH 密钥。

## Ubuntu debug rootfs

```sh
sudo scripts/build-rootfs.sh
sudo scripts/check-rootfs.sh
sudo scripts/mk-ext4-image.sh
```

默认输出位于 `out/`。该 rootfs 主要用于 bring-up 和内核调试，不作为最终桌面发行版目标。

## Fedora/KDE rootfs

从 Fedora 包仓库构建：

```sh
sudo scripts/build-fedora-rootfs.sh
```

从 Fedora aarch64 桌面镜像导入：

```sh
FEDORA_IMAGE_URL=<fedora-aarch64-raw-xz-url> sudo scripts/import-fedora-desktop-image.sh
sudo scripts/check-fedora-rootfs.sh
```

脚本默认禁用 SSH 密码登录，并锁定 root 密码。需要创建本地用户或设置密码时，通过 `local/fedora.env` 或环境变量传入，不应把本地密码、hash、authorized_keys 或固件提交到仓库。

## 分区和镜像

`partition-geometry.py` 用于计算 lmi 设备上的 Linux/rootfs 分区布局；`mk-ext4-image.sh` 用于把 rootfs 输出转换为可写入的 ext4/sparse 镜像。实际写盘和分区操作应在执行前再次核对设备节点和 manifest。

## 开源边界

本仓库不是硬件适配的长期承载位置。音频、显示、触摸、Wi-Fi、蓝牙、充电、启动菜单等设备支持应回到主内核、DTS、initramfs 或 boot 支持层；rootfs 里的调试脚本只保留能帮助复现实机验证的最小内容。
