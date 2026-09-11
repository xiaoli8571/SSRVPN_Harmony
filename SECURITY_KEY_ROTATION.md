# SSRVPN 签名材料轮换清单（待用户执行）

> **状态：未执行。** 本文档由安全收口子任务生成，仅列出**需要用户人工完成**的步骤。
> 代码侧收口（明文口令清除、白名单提交、扫描器、.gitignore）已完成；**密钥/证书轮换必须由持有者本人操作**，本仓库未、也不会代为执行。

---

## 1. 为什么必须轮换

历史审计与本次收口确认：发布签名口令曾以**明文**形式存在于仓库多个文件与 Git 历史中（详见第 5 节）。任何曾进入 Git 历史或快照文件的口令都必须视为**已泄露**，对应的 P12 与证书链必须轮换，而不仅仅是删除文件。

**处置原则**：删除明文字符串 ≠ 口令安全。口令值一旦写入被提交的文件、构建日志或被推送到远端，就必须假定攻击者可获取。

---

## 2. 需要轮换的对象

| 对象 | 路径 | 处置 |
|---|---|---|
| 发布签名密钥库 | `SSRVPN.p12` | **必须轮换**（重新生成密钥+口令） |
| 旧密钥库 | `SSRVPN-legacy.p12` | **必须轮换或彻底停用** |
| 发布证书 | `SSRVPN.cer` | 随新 p12 重新签发 |
| 发布 Profile | `SSRVPNRelease.p7b` | 在 AGC 用新证书重新申请 |
| CSR | `ssrvpn.csr` | 用新私钥重新生成 |
| 签名口令（key/store 共用） | 曾明文出现 | **必须更换为新口令** |
| GitHub PAT | 曾用于推送（脚本交互输入，未落盘） | 建议一并重置 |

> 不要删除 `SSRVPN.p12 / SSRVPN.cer / SSRVPNRelease.p7b` 这组正式文件，直到新证书链在 AGC 生效并可正常签名通过为止。

---

## 3. 轮换操作步骤（用户执行）

### 3.1 生成新密钥库与新口令
1. 在 **DevEco Studio** 中打开 `File > Project Structure > Signing Configs`。
2. 取消勾选自动签名，选择 **“New”** 新建密钥库，`Generate Key and CSR`：
   - 算法：**ECDSA P-256 (SHA256withECDSA)**（与现网一致，勿改算法）。
   - alias：`ssrvpn`（保持一致，避免脚本改动）。
   - 设置**全新的强口令**（≥16 位，含大小写+数字+符号，且**与旧口令无任何关联**）。
3. 保存到仓库根目录，建议新文件名如 `SSRVPN-v2.p12`，导出新 `.csr`。

### 3.2 重新签发证书与 Profile
1. 前往 **AppGallery Connect (AGC) → 证书、App ID 和 Profile → 证书**，用新 `.csr` 申请新发布证书 → 下载新 `.cer`。
2. 在 **Profile** 中用新证书与目标 App ID 重新申请发布 Profile → 下载新 `.p7b`。
3. 校验三者匹配：
   ```powershell
   # 证书与私钥的公钥指纹应一致（不打印私钥或口令）
   keytool -list -keystore .\SSRVPN-v2.p12 -storetype PKCS12
   ```
   > 会提示输入口令，**输入时不要粘贴到任何聊天/日志**。

### 3.3 停用旧材料
1. 在 AGC 中**吊销**旧发布证书（如界面支持）。
2. 旧 `SSRVPN.p12 / SSRVPN-legacy.p12` 移出仓库目录，加密归档或安全销毁：
   - Windows：`cipher /w:C:\path` 覆写空闲空间，或使用厂商安全擦除工具。
3. 确认新口令**不写入任何文件**：运行脚本时只通过环境变量或交互输入提供。

### 3.4 配置新口令的读取方式
发布脚本已改为**绝不存储口令**，按优先顺序读取：
```powershell
# 方式 A（推荐，会话级环境变量，不落盘）
$env:SSRVPN_KEY_PASSWORD = '<新口令>'
powershell -ExecutionPolicy Bypass -File .\build-sign-publish.ps1

# 方式 B（不设环境变量时，脚本会交互式掩码提示输入）
.\build-sign-publish.ps1
```
> 建议把 `$env:SSRVPN_KEY_PASSWORD` 写进**本机用户级**注册表或凭据管理器（`cmdkey`），用完 `Remove-Item Env:\SSRVPN_KEY_PASSWORD`；**切勿**写进 `.ps1`、`.json5`、`.env` 等会被提交的文件。

---

## 4. 已发布包的签名链核查

对每个已发布（或本机 `Downloads` 中留存的）`.app / .hap` 逐个核查：

```powershell
# 1) 查看包内签名块（DevEco 自带工具）
java -jar "$env:DEVECO_SDK_HOME\default\openharmony\toolchains\lib\hap-sign-tool.jar" verify-app `
  -inFile .\SSRVPN_HarmonyOS-v5.2-release-signed.app -outCertChain out-chain.cer -outProfile out.p7b
```
- **判据**：输出的证书链根/签发者应与**旧证书**一致 → 说明该包由**已泄露密钥**签署。
- 若包被**上架 AGC**：在 AGC 控制台核对已上架版本对应的证书指纹。
- 若包仅在 GitHub Release / 侧载分发：
  1. 记录每个已发布版本的证书指纹（`keytool -printcert -file out-chain.cer`）。
  2. 与旧证书指纹比对；命中即列入**受影响清单**。
  3. 对受影响版本：**用新证书重新签名并重新发布**，并在 Release Notes 注明“签名证书已轮换，请重新下载”。

> 核查产物 `out-chain.cer / out.p7b` 属于敏感材料，核查后删除，切勿提交。

---

## 5. 明文口令历史位置（不含口令值）

已从**工作区文件**中清除；但**以下路径的历史版本（含已提交的 Git 历史）中仍留有明文**，需按第 6 节处理：

| # | 文件路径 | 行号 |
|---|---|---|
| 1 | `SSRVPN_HarmonyOS-LightTheme-Rollback-20260909-221922\_parent_build-sign-publish.ps1` | 22 |
| 2 | `SSRVPN_HarmonyOS-LightTheme-Rollback-20260909-221922\build-profile.json5` | 10, 14 |
| 3 | `SSRVPN_HarmonyOS-PreFix-Snapshot-20260909-222141\repo-files\build-profile.json5` | 10, 14 |
| 4 | `SSRVPN_HarmonyOS-PreFix-Snapshot-20260909-222141\working-tree.patch` | 31, 35 |
| 5 | `SSRVPN_HarmonyOS-before-fix-20260909-174217.patch` | 133, 137 |
| 6 | `build-sign-publish.ps1`（Git HEAD 版本，工作区已修复） | 历史行 |

> 未找到口令值的其他落盘位置（`material/` 为空；`mihomo-build/` 内为上游 Go 源码的字段名，非本项目口令）。

---

## 6. Git 历史与已推送内容（建议，不自动执行）

本仓库**未执行任何 Git 历史改写**。若含明文口令的文件曾被推送到远端，仅清除工作区文件不足够：

- 需由用户决策后**人工执行** `git filter-repo`（或 BFG）清理历史中的上述文件，然后 `git push --force-with-lease`。
- 或：确认远端仓库为私有且接受残留风险，则**仅轮换密钥**（最经济，且轮换后旧口令失效，残留明文失去价值）。
- **无论如何都不要**回显、粘贴口令值到任何 Issue / PR / 聊天。

---

## 7. 完成检查表（用户勾选）

- [ ] 新 `SSRVPN-v2.p12` 生成，算法 ECDSA P-256，alias 仍为 `ssrvpn`
- [ ] 新口令为全新强口令，未写入任何文件
- [ ] 新 `.cer` / `.p7b` 已在 AGC 签发并替换
- [ ] 旧证书已吊销，旧 p12/csr 已加密归档或安全销毁
- [ ] 已发布包签名链核查完成，受影响版本已列出并重签
- [ ] 本机环境变量 / 凭据管理器已配置新口令，脚本可正常签名
- [ ] 已决定是否清理 Git 历史，并（如决定）人工执行
- [ ] `.gitignore` 复核：快照/证书/日志/patch 均被忽略

---

*生成方：安全收口子任务 · 状态：待用户执行*
