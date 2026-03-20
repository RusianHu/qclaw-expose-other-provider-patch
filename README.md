# QClaw expose-other-provider patch

一个面向 `QClaw 0.1.13` 的 PowerShell 补丁脚本，用于把“大模型设置”中的一个现有固定厂商槽位替换为“其他”，从而进入程序内置但默认未暴露的 custom provider 分支。

## 功能

- 自动识别 `QClaw` 安装目录
- 默认校验目标版本为 `0.1.13`
- 使用等长原位补丁修改 `resources/app.asar`
- 提供状态探测、干跑、正式补丁、反修补、基于备份回滚
- 备份与副本统一输出到脚本同级子目录 `QClawPatches`

## 适用范围

- 默认面向 `QClaw 0.1.13`
- 其他版本需要先执行状态探测或干跑，并谨慎配合 `-AllowUnknownVersion`

## 使用方法

### 状态探测

```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -Status
```

### 干跑

```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -DryRun
```

### 正式补丁

```powershell
& '.\patch-qclaw-expose-other-provider.ps1'
```

### 反修补 / 卸载补丁

```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -Unpatch
```

### 回滚

```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -Restore
```

### 指定安装目录

```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -InstallRoot 'D:\Apps\QClaw' -DryRun
& '.\patch-qclaw-expose-other-provider.ps1' -InstallRoot 'D:\Apps\QClaw'
```

## 状态含义

- `STATUS=PATCHED_OR_OPEN`：已修补或该入口已开放
- `STATUS=UNPATCHED_PATCHABLE`：未修补，但当前版本可安全补丁
- `STATUS=UNSUPPORTED_BUILD`：未命中保护特征，拒绝补丁
- `STATUS=AMBIGUOUS`：定位串出现多次，拒绝补丁
- `STATUS=UNKNOWN`：特征不匹配，需要人工复核

## 注意事项

- 目标位于 `Program Files` 时，正式补丁、反修补、回滚都必须使用管理员 PowerShell
- 该补丁是替换现有槽位，不是在列表末尾新增真正的新项
- 软件更新后大概率需要重新评估兼容性
- 正式写回不是原子操作，执行前请确保系统稳定并保留备份

## 输出目录

脚本会在当前脚本目录下创建：

- `QClawPatches\*.bak`
- `QClawPatches\*.patched`
- `QClawPatches\*.unpatched`

## License

本项目使用 `GPL-3.0` 许可证，详见 `LICENSE`。
