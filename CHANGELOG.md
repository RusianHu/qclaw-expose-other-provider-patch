# Changelog

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
