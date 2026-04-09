# QClaw expose-other-provider patch

## 目标
- 暴露“大模型设置”中的“其他”选项，进入内置但默认未暴露的 custom provider 分支。
- 已重新适配 `QClaw 0.2.5`；默认要求版本匹配，也支持显式放宽版本限制后再做特征校验。
- 保留对旧 `0.1.16 / 0.1.13` guard 特征的兼容识别，并内嵌 `skillhub_install` regex 兼容修复。
- `QClaw 0.2.4 / 0.2.5` 除静态 `doubao` 槽位外，还会通过 `modelApi` 远端返回值覆盖本地下拉；主脚本现已内嵌该覆盖禁用修补。
- 本文档和 `README.md` 更新时要求保持精简、高信息熵。

# 备注 
- 本机的 Qclaw 地址 `C:\Program Files\QClaw`，授权你进行充分的调试。

## 已做工作
- 逆向确认前端 `ModelSettingModal` 已内置 `provider === "other"` 分支：会显示 `Base URL / API Key / 模型名称`。
- 逆向确认 UI 下拉数组未直接暴露 `other`，但仍保留 `doubao` 槽位，适合继续做**等长原位替换**。
- 逆向确认 `QClaw 0.2.4 / 0.2.5` 在本地静态 provider 列表之外，还会通过 `modelApi` 远端返回值覆盖 UI 下拉；只做 `doubao -> other` 不足以稳定生效。
- `0.1.19 / 0.1.20 / 0.1.22 / 0.2.1 / 0.2.4 / 0.2.5` 中 `other` guard 压缩变量名均已纳入兼容特征集合。
- 当前采用**双位点等长原位补丁**，避免完整解包/重打 `app.asar`：
  - provider 槽位：`key:"doubao",label:"火山引擎（豆包）"` → `key:"other",label:"其他"`
  - 远端覆盖位点：`0.2.4` 使用 `t.data&&t.data.length>0&&(Eo=t.data,hu(Eo,"modelApi"))`，`0.2.5` 使用 `t.data&&t.data.length>0&&(Ko=t.data,Ru(Ko,"modelApi"))`；两者均修补为对应的 `length<0`
- 已定位并修复 `QClaw 0.1.19 / 0.1.20 / 0.1.22 / 0.2.1 / 0.2.4 / 0.2.5` 内置 `skillhub_install` 工具的 regex 兼容性问题；其中 `0.1.20 / 0.1.22 / 0.2.1 / 0.2.4 / 0.2.5` 兼容 runtime 旧式 + schema 过渡态，该修复现已内嵌到主脚本，按版本/特征自动执行。
- 脚本已提供自动探测安装目录、版本校验、特征校验、DryRun、状态探测、备份、回滚、反修补能力。
- 备份/副本统一输出到脚本同级子目录 `QClawPatches`，便于集中管理。

## 核心策略（允许根据实际情况灵活调整，并及更新）
1. 自动识别安装目录：运行中进程 → 注册表 → 常见路径。
2. 校验版本：默认 `0.2.5`。
3. 校验特征：
   - 必须命中原始 `doubao` 特征串或已补丁 `other` 特征串。
   - 必须命中**任一兼容的** `other` 分支校验逻辑特征串。
   - 对 `modelApi` 远端覆盖位点，必须命中原始特征或已修补特征之一。
   - 各定位串只能出现一次，否则拒绝补丁 / 反修补。
4. 先生成 patched 副本，再写回目标 `resources/app.asar`。
5. 若命中 `0.1.19 / 0.1.20 / 0.1.22 / 0.2.1 / 0.2.4 / 0.2.5` 且检测到兼容的 `skillhub_install` regex 旧特征或过渡特征，则在**同一执行流**内顺带修补 `skillhub-installer.ts`。
6. `QClaw 0.2.4 / 0.2.5` 若仅完成 provider 槽位替换、但 `modelApi` 远端覆盖仍未禁用，则应视为**半修补状态**并继续补齐。
7. 写回前停止 `QClaw.exe`，写回后做哈希一致性校验。
8. 检测当前终端是否管理员：
   - `-Status` / `-DryRun` / `-PrintDetectedRoot` 可在非管理员终端继续执行。
   - 正式补丁与 `-Restore` 若非管理员会直接拒绝，并给出明确提示。

## 使用
### 状态探测
```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -Status
```

### 干跑
```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -DryRun
```

### 正式补丁（管理员 PowerShell）
```powershell
& '.\patch-qclaw-expose-other-provider.ps1'
```

### 指定安装目录
```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -InstallRoot 'D:\Apps\QClaw' -DryRun
& '.\patch-qclaw-expose-other-provider.ps1' -InstallRoot 'D:\Apps\QClaw'
```

### 反修补 / 卸载补丁
```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -Unpatch
```

### 回滚
```powershell
& '.\patch-qclaw-expose-other-provider.ps1' -Restore
```

## 状态输出含义
- `STATUS=PATCHED_OR_OPEN`：已修补或该特殊入口已开放
- `STATUS=PATCHED_NEEDS_REMOTE_OVERRIDE_FIX`：provider 槽位已替换，但 `modelApi` 远端 provider 覆盖仍待修补
- `STATUS=UNPATCHED_PATCHABLE`：未修补，但当前版本可安全补丁
- `STATUS=UNSUPPORTED_BUILD`：未命中任何兼容的 `other` 分支保护特征，拒绝补丁
- `STATUS=AMBIGUOUS`：定位串出现多次，拒绝补丁
- `STATUS=UNKNOWN`：特征不匹配，需人工复核
- `ALREADY_PATCHED`：执行正式补丁前检测到目标已处于补丁后特征状态
- `REMOTE_OVERRIDE_FIX=PATCH / ALREADY_FIXED / SKIP_FEATURE`：表示 `modelApi` 远端覆盖位点是否待修、已修或当前构建未命中

## 注意事项
- 目标文件位于 `Program Files` 下时，正式补丁/反修补/回滚必须用**管理员 PowerShell**执行。
- 非管理员终端下，脚本会给出提示，但仍允许 `-Status` / `-DryRun` / `-PrintDetectedRoot` 继续执行。
- 软件更新后大概率需要重新评估；本次已确认 `0.2.5` 的主要变化包括新的 `other` guard 压缩片段、`modelApi` 远端覆盖变量名从 `Eo/hu` 变为 `Ko/Ru`，以及 `skillhub_install` 继续延续 runtime 旧式 + schema 过渡态。
- 该补丁本质上仍是**替换一个现有固定厂商槽位**为“其他”，不是在列表末尾真正新增新项。
- `QClaw 0.2.4 / 0.2.5` 若只改动 provider 槽位而未禁用 `modelApi` 远端覆盖，UI 仍可能显示“火山引擎（豆包）”；当前主脚本已将该二阶段修补并入同一执行流。
- 若目标环境已补丁，脚本会输出 `ALREADY_PATCHED` 或 `STATUS=PATCHED_OR_OPEN`；若仅剩附带热修补待做，`-DryRun` 会返回包含 `REMOTE_OVERRIDE` / `SKILLHUB` / `SHARP` 的 `MODE=*FIX_ONLY`。
- 若之前用旧版本脚本修补过，随后又升级了 `QClaw`，旧残留可能导致正式执行失败、状态异常或运行异常；此时建议先重新安装 `QClaw`（`https://qclaw.qq.com/`），再使用**管理员 PowerShell**重新运行脚本。
- 若需支持更多版本，应优先先跑 `-Status` 或 `-DryRun`，必要时再用 `-AllowUnknownVersion` 做受控验证。
- 若后续官方稳定开放 `other` provider`、停用动态 provider 覆盖，或修复 `skillhub_install` schema`，该补丁及其附带热修补应优先评估下线，必要时可直接删除相关逻辑。

## 交付物
- `patch-qclaw-expose-other-provider.ps1`：自动探测安装目录 + 管理员检测 + 双位点安全补丁/反修补脚本。
- 本文件：面向后续维护/分发者的高密度说明。
- `0.2.5` 实机结果：`STATUS=UNPATCHED_PATCHABLE` → 管理员正式执行 `PATCH_OK` → 复核 `STATUS=PATCHED_OR_OPEN`，同时 `REMOTE_OVERRIDE_FIX=ALREADY_FIXED`、`SHARP_STATE=OK`。
