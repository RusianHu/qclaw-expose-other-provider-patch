# Changelog

## v0.2.6 - 并入 sharp 自检/自修复并补齐只读验证

### 更新摘要
- 将 `sharp` 运行时依赖检查并入主脚本，不再依赖外置一次性修复脚本
- 新增 `resources/openclaw/package.json` 声明探测、`import("sharp")` 自检、失败原因归类与状态输出
- 当 `app.asar` 已补丁但 `sharp` 缺失 / 损坏时，可自动进入 `SHARP_FIX_ONLY` 或 `SKILLHUB_AND_SHARP_FIX_ONLY`
- `sharp` 修复统一走 `npm install sharp@<declared-version> --no-save --package-lock=false --omit=dev --legacy-peer-deps --registry=https://registry.npmmirror.com`
- `-Status` / `-DryRun` / `ALREADY_PATCHED` / `PATCH_OK` 新增 `SHARP_FIX / SHARP_STATE / SHARP_DETAIL / SHARP_IMPORT_OK / SHARP_MODULE_DIR`

### 实机验证
- 实测安装目录：`C:\Program Files\QClaw`
- 实测目标版本：`QClaw 0.2.1`
- 当前环境状态探测：`STATUS=PATCHED_OR_OPEN`
- 当前环境 `sharp` 状态：`SHARP_FIX=ALREADY_OK`，`SHARP_STATE=OK`，`SHARP_IMPORT_OK=YES`
- 已补丁环境干跑：`ALREADY_PATCHED`
- 反修补干跑：`DRY_RUN_OK`
- PowerShell 解析校验：通过

### 兼容性说明
- `sharp` 自修复仅在 `resources/openclaw/package.json` 已声明 `sharp` 且本机存在 `node` / `npm` 时启用
- 若 `sharp` 已可正常导入，脚本只输出状态，不会重复安装
- 现有 `other provider` 等长补丁、ASAR 完整性修复、`skillhub_install` 热修补逻辑保持不变

### 升级建议
- 已使用 `v0.2.5` 的用户可直接替换主脚本，无需再保留外置 `sharp` 修复脚本
- 若目标环境位于 `Program Files`，正式补丁、附带热修补、反修补、回滚仍需管理员 PowerShell
- 后续若继续支持新版本，优先复用当前 `searchText + guard + skillhub path + sharp state` 的识别框架扩展

## v0.2.5 - 适配 QClaw 0.2.1 并完成实机验证

### 更新摘要
- 默认目标版本从 `QClaw 0.1.22` 更新为 `QClaw 0.2.1`
- 原始定位串适配为 `key:"doubao",label:"火山引擎（豆包）"`，继续保持等长原位替换
- 新增 `QClaw 0.2.1` 的 `other guard` 压缩特征识别：`Xe.warning + f/g/h/m`
- `skillhub_install` 热修补扩展到 `0.2.1`
- 兼容 `QClaw 0.2.1` 中 `skillhub-installer.ts` 新路径：`qclaw-plugin/packages/content-plugin/src`
- 保持 runtime 旧式 Unicode regex + schema 过渡态 `^[\\w\\-\\.]{1,128}$` 的自动修补

### 实机验证
- 实测安装目录：`C:\Program Files\QClaw`
- 实测目标版本：`QClaw 0.2.1`
- 旧脚本默认状态探测：版本校验失败
- 放宽版本后状态：`STATUS=UNSUPPORTED_BUILD`，`DETAIL=missing_other_guard`
- 重新适配后状态：`STATUS=UNPATCHED_PATCHABLE`
- 干跑结果：`DRY_RUN_OK`，`SKILLHUB_REGEX_FIX=PATCH`
- 正式补丁结果：`PATCH_OK`
- 补丁后状态：`STATUS=PATCHED_OR_OPEN`
- 反修补干跑结果：`DRY_RUN_OK`

### 兼容性说明
- 继续保留对旧 `0.1.16 / 0.1.13` guard 特征的兼容识别
- `QClaw 0.1.19 / 0.1.20 / 0.1.22 / 0.2.1` 已启用 Electron ASAR 完整性校验，脚本会同步修复：
  - ASAR 目标文件 `integrity`
  - `QClaw.exe` 内嵌 `ELECTRONASAR` 头部哈希
- `QClaw 0.2.1` 的 `skillhub-installer.ts` 路径变更已纳入自动识别
- 若后续官方稳定开放 `other provider`，或修复 `skillhub_install` 相关兼容问题，应优先评估下线本补丁

### 升级建议
- 已在旧版本脚本基础上手工改过文件的用户，建议直接替换为当前脚本版本后重新执行 `-Status` / `-DryRun`
- 若目标环境位于 `Program Files`，正式补丁、反修补、回滚仍需管理员 PowerShell
- 发布后若需支持新版本，优先复用当前 `searchText + guard + skillhub path` 识别框架继续扩展

## v0.2.4 - 适配 QClaw 0.1.22 并完成实机验证

### 更新摘要
- 默认目标版本从 `QClaw 0.1.20` 更新为 `QClaw 0.1.22`
- 新增 `QClaw 0.1.22` 的 `other guard` 压缩特征识别：`Ze.warning + v/g/h/m`
- 扩展 `skillhub_install` 热修补到 `0.1.19 / 0.1.20 / 0.1.22`
- 兼容 `QClaw 0.1.22` 中 `skillhub-installer.ts` 的过渡态：
  - runtime 仍为旧式 Unicode regex
  - schema 已收敛为 `^[\\w\\-\\.]{1,128}$`
- 同步更新 `README.md` 与 `AGENTS.md` 的版本说明、适用范围、注意事项

### 实机验证
- 实测安装目录：`C:\Program Files\QClaw`
- 实测目标版本：`QClaw 0.1.22`
- 旧脚本默认状态探测：版本校验失败
- 放宽版本后状态：`STATUS=UNSUPPORTED_BUILD`，`DETAIL=missing_other_guard`
- 新增 0.1.22 guard 后状态：`STATUS=UNPATCHED_PATCHABLE`
- 干跑结果：`DRY_RUN_OK`
- 正式补丁结果：`PATCH_OK`
- 实测已确认 `skillhub-installer.ts` 同步修补成功，输出 `SKILLHUB_REGEX_FIX=PATCH`

### 兼容性说明
- 继续保留对旧 `0.1.16 / 0.1.13` guard 特征的兼容识别
- `QClaw 0.1.19 / 0.1.20 / 0.1.22` 已启用 Electron ASAR 完整性校验，脚本会同步修复：
  - ASAR 目标文件 `integrity`
  - `QClaw.exe` 内嵌 `ELECTRONASAR` 头部哈希
- 若后续官方稳定开放 `other provider`，或修复 `skillhub_install` 相关兼容问题，应优先评估下线本补丁

### 升级建议
- 已在旧版本脚本基础上手工改过文件的用户，建议直接替换为当前脚本版本后重新执行 `-Status` / `-DryRun`
- 若目标环境位于 `Program Files`，正式补丁、反修补、回滚仍需管理员 PowerShell
- 发布后若需支持新版本，优先复用当前 `guard + skillhub transitional schema` 的识别框架继续扩展

## v0.2.3 - 适配 QClaw 0.1.20 并完成实机验证

### 更新摘要
- 默认目标版本从 `QClaw 0.1.19` 更新为 `QClaw 0.1.20`
- 新增 `QClaw 0.1.20` 的 `other guard` 压缩特征识别
- 扩展 `skillhub_install` 热修补到 `0.1.19 / 0.1.20`
- 兼容 `QClaw 0.1.20` 中 `skillhub-installer.ts` 的过渡态：
  - runtime 仍为旧式 Unicode regex
  - schema 已收敛为 `^[\\w\\-\\.]{1,128}$`
- 同步更新 `README.md` 与 `AGENTS.md` 的版本说明、适用范围、注意事项

### 实机验证
- 实测安装目录：`C:\Program Files\QClaw`
- 实测目标版本：`QClaw 0.1.20`
- 修复前状态：`STATUS=UNSUPPORTED_BUILD`
- 重新适配后状态：`STATUS=UNPATCHED_PATCHABLE`
- 干跑结果：`DRY_RUN_OK`
- 正式补丁后状态：`STATUS=PATCHED_OR_OPEN`
- 实测已确认 `skillhub-installer.ts` 同步修补成功，patched runtime/schema 均唯一命中

### 兼容性说明
- 继续保留对旧 `0.1.16 / 0.1.13` guard 特征的兼容识别
- `QClaw 0.1.19 / 0.1.20` 已启用 Electron ASAR 完整性校验，脚本会同步修复：
  - ASAR 目标文件 `integrity`
  - `QClaw.exe` 内嵌 `ELECTRONASAR` 头部哈希
- 若后续官方稳定开放 `other provider`，或修复 `skillhub_install` 相关兼容问题，应优先评估下线本补丁

### 升级建议
- 已在旧版本脚本基础上手工改过文件的用户，建议直接替换为当前脚本版本后重新执行 `-Status` / `-DryRun`
- 若目标环境位于 `Program Files`，正式补丁、反修补、回滚仍需管理员 PowerShell
- 发布后若需支持新版本，优先复用当前 `guard + skillhub transitional schema` 的识别框架继续扩展
