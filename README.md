# QClaw expose-other-provider patch

一个面向 **QClaw** 的修补脚本，用于把“大模型设置”中的 doubao 选项替换为 “其他” ，从而进入程序内置但默认未暴露的 custom provider 分支，允许使用第三方 `Openai-Completions` 协议的模型。

<img width="1200" height="800" alt="image" src="https://github.com/user-attachments/assets/14a173e6-689e-43d4-bb86-869fc2c0c23f" />

## 功能

- 自动识别 `QClaw` 安装目录
- 默认校验目标版本为 `0.2.1`
- 使用等长原位补丁修改 `resources/app.asar`
- 同步修复 ASAR 内部文件完整性记录与 `QClaw.exe` 内嵌 `ELECTRONASAR` 头部哈希
- 对 `QClaw 0.1.19 / 0.1.20 / 0.1.22 / 0.2.1` 自动执行 `skillhub-installer.ts` 的 regex 兼容热修补，并兼容旧路径与 `qclaw-plugin/packages` 新路径
- 自动探测 `resources/openclaw` 中 `sharp` 运行时依赖是否缺失 / 损坏，并在需要时顺带自修复
- `sharp` 自修复使用 `npm install sharp@<declared-version> --no-save --package-lock=false --omit=dev --legacy-peer-deps --registry=https://registry.npmmirror.com`
- 提供状态探测、干跑、正式补丁、反修补、基于备份回滚
- 可自动修复“已补丁但完整性未同步”的旧补丁状态
- 备份与副本统一输出到脚本同级子目录 `QClawPatches`

## 适用范围

- 默认面向 `QClaw 0.2.1`
- 保留对旧 `0.1.16 / 0.1.13` guard 特征的兼容识别
- 已新增 `0.1.19 / 0.1.20 / 0.1.22 / 0.2.1` 的 `other guard` 特征兼容识别
- 已内嵌 `0.1.19 / 0.1.20 / 0.1.22 / 0.2.1` 的 `skillhub_install` regex 兼容修复
- 其中 `0.1.20 / 0.1.22 / 0.2.1` 已兼容 runtime 仍为旧式 Unicode regex、schema 收敛为 `^[\\w\\-\\.]{1,128}$` 的过渡状态
- `QClaw 0.2.1` 的 `skillhub-installer.ts` 已迁移到 `qclaw-plugin/packages/content-plugin/src`，脚本会自动识别新旧路径

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
- `STATUS=UNKNOWN`：特征不匹配，或检测到完整性不同步，需要人工复核 / 修复
- `SHARP_FIX=PATCH / ALREADY_OK / SKIP`：表示当前 `sharp` 依赖是否需要修复、已正常、或已跳过检查
- `SHARP_STATE / SHARP_DETAIL / SHARP_IMPORT_OK / SHARP_MODULE_DIR`：分别表示 `sharp` 检测状态、失败原因、自检导入结果、模块目录是否存在

## 注意事项

- 目标位于 `Program Files` 时，正式补丁、反修补、回滚都必须使用管理员 PowerShell
- 该补丁是替换现有槽位，不是在列表末尾新增真正的新项
- `QClaw 0.1.19 / 0.1.20 / 0.1.22 / 0.2.1` 已启用 Electron ASAR 完整性校验；仅修改 `resources/app.asar` 而不同步完整性元数据，会导致程序无法启动
- 当前脚本会同步更新 ASAR 头部中的目标文件完整性记录，并回写 `QClaw.exe` 内嵌的 `ELECTRONASAR` 头部哈希
- 对 `skillhub_install` 的 regex 修复不是外置二次脚本，而是主脚本在同一执行流内按版本/特征自动判定后顺带执行；`0.2.1` 的新路径与过渡 schema 均已纳入兼容识别
- 对 `sharp` 的修复同样已经并入主脚本：若 `package.json` 已声明 `sharp`，但运行时 `import("sharp")` 失败，则在正式执行流里自动补装并再次校验
- `-DryRun` 在 `app.asar` 已补丁但仅剩附带热修补待做时，会返回 `MODE=SKILLHUB_FIX_ONLY` / `SHARP_FIX_ONLY` / `SKILLHUB_AND_SHARP_FIX_ONLY`
- 若历史上曾应用过旧版错误补丁，重新执行正式补丁会自动进入修复模式
- 已实测 `QClaw 0.2.1`：重新适配后可得到 `STATUS=UNPATCHED_PATCHABLE` → `PATCH_OK` → `STATUS=PATCHED_OR_OPEN`，且 `-DryRun -Unpatch` 可通过；当前环境 `-Status` / `-DryRun` 也已确认输出 `SHARP_FIX=ALREADY_OK`
- 软件更新后大概率需要重新评估兼容性
- 若后续官方稳定开放 `other` provider`、修复 `skillhub_install` schema`，或内置依赖管理恢复稳定，本补丁及附带热修补应优先评估下线，必要时可直接删除相关逻辑
- 正式写回不是原子操作，执行前请确保系统稳定并保留备份

## 输出目录

脚本会在当前脚本目录下创建：

- `QClawPatches\*.bak`
- `QClawPatches\*.patched`
- `QClawPatches\*.unpatched`

## License

本项目使用 `GPL-3.0` 许可证，详见 [LICENSE](LICENSE)。
