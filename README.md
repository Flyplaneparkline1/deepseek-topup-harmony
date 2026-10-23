# DS 充值壳（HarmonyOS）

一个只做一件事的鸿蒙 App：**一键直达 DeepSeek 开放平台充值页、免重复登录、顶部常显余额。**

> 纯血鸿蒙（HarmonyOS NEXT）没有安卓兼容层，**APK 装不上，只能 HAP**。所以这是 ArkTS + ArkWeb 原生工程，不是套壳安卓。

---

## 构建状态（本机实测）

| 项 | 值 |
| --- | --- |
| IDE / SDK | DevEco Studio 26.0 · HarmonyOS 26.0.0（API 26） |
| compatibleSdkVersion | 6.1.1(24)（手机那一档） |
| hvigor | 6.26.4 |
| 编译结果 | `BUILD SUCCESSFUL`，**0 个 ArkTS 警告** |
| 产物 | `entry/build/default/outputs/default/entry-default-unsigned.hap`（约 154 KB） |
| 签名 | ❌ 未配置，产物是 **unsigned**，装不上机（见下节） |

命令行编译（不打开 IDE 也能出包）：

```bash
export DEVECO_SDK_HOME="D:\softw\deveco-studio\DevEco Studio\sdk"
"$DEVECO_SDK_HOME/../tools/node/node.exe" \
  "$DEVECO_SDK_HOME/../tools/hvigor/hvigor/bin/hvigor.js" \
  --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

---

## 功能

| 功能 | 实现 |
| --- | --- |
| 启动即充值页 | 直接加载 `platform.deepseek.com/top_up`，跳过官网首页 |
| 免重复登录 | ArkWeb 默认把 Cookie 持久化在应用沙箱，一次短信登录管很久 |
| 支付链路 | 拦截 `alipays://` / `weixin://`，转成 Want 交给系统拉起支付宝/微信 |
| 回到前台自动同步 | 从支付宝回来后自动刷新页面同步订单，顺带刷余额 |
| 余额常显 | 顶部胶囊调 `GET /user/balance` 显示 CNY 余额，点一下手动刷新 |
| 返回键 | 网页内部后退优先，退无可退才退出 App |

**不做什么**：不接管支付、不保存密码、不碰订单接口。付款全程在官方网页 + 支付宝里完成。

---

## 文件地图

```
entry/src/main/
├── ets/entryability/EntryAbility.ets   # 入口：initializeWebEngine() 预热内核，减少白屏
├── ets/pages/Index.ets                 # 全部逻辑：Web + 协议拦截 + 余额 + Key 存储
├── module.json5                        # ← 权限 / querySchemes 在这
└── resources/base/profile/main_pages.json

AppScope/app.json5                      # bundleName: com.mikann.dstopup（要改就改这里）
```

**`module.json5` 里两个不能删的字段**：

```json5
"requestPermissions": [{ "name": "ohos.permission.INTERNET" }],
"querySchemes": ["alipays", "alipayqr", "alipay", "weixin"]   // 缺了它，startAbility 拉不起支付宝
```

---

## 怎么装到手机上（当前唯一的门槛）

鸿蒙**没有「下载 HAP 双击安装」**这回事：HAP 必须签名，签名 profile 里绑定了允许安装的设备 UDID。

1. 手机开「开发者选项 → USB 调试」，插线
2. DevEco：`File → Project Structure → Signing Configs` → 勾 **Automatically generate signature** → 登录华为账号
3. 右上角选设备 → **Run**

签名成功后产物变成 `entry-default-signed.hap`，也可以 `hdc install -r <path>`（`hdc` 在 `D:\softw\tools\hdc\hdc.exe` 或 SDK 的 `toolchains/`）。

**注意**
- 自动生成的调试证书有有效期（通常 90 天上下，以 IDE 提示为准）。过期 App 会打不开，重新自动签名再装一次即可，代码不用动。
- 换手机/平板 = 新 UDID，需要重新加进调试 profile。
- 本机 `D:\softw\deveco-studio\signing\` 里那套 `mikann.p12` + `*.p7b` 是给另一个应用（bundleName 不同）签的，**不能直接拿来签本项目**，且 p12 密码未知。

---

## 支付链路（排错看这段）

```
网页里点「支付宝支付」
  → 跳 alipays://platformapi/startapp?...
  → ArkWeb 不认识这个协议，会白屏
  → Index.ets: onLoadIntercept 拦到 → return true 阻止加载
  → 拼 Want{ action:'ohos.want.action.viewData', uri:'alipays://...' } → startAbility
  → 系统拉起支付宝 → 付款 → 返回
  → 页面 onPageShow → controller.refresh() → 余额更新
```

| 现象 | 原因 / 处理 |
| --- | --- |
| 点支付白屏、没反应 | `querySchemes` 没声明，或 `isExternalScheme()` 没匹配到 → 在 `onLoadIntercept` 里 `console.info('URL: ' + url)` 看实际协议头 |
| 提示"无法打开外部应用" | 设备没装支付宝/微信，或 scheme 拼错 |
| 付款回来页面还是旧状态 | 支付是在 **iframe** 里发起的，`onLoadIntercept` 只拦主框架导航 —— 需要补 `onInterceptRequest`（Roadmap 里已列） |
| 每次都要重新登录 | 应用数据被系统清理；Cookie 存在应用沙箱内 |

---

## Roadmap

- [ ] **服务卡片（Widget）**：桌面直接显示余额 + 一键充值（鸿蒙卡片体验比安卓好，性价比最高）
- [ ] 低余额本地通知（`notificationManager`，需用户授权）
- [ ] iframe 内支付协议拦截：`onInterceptRequest` + `onNavigationEntryCommitted`
- [ ] 金额快捷入口（注入 JS 或带 query 参数直达）
- [ ] 平板横屏布局：左侧信息栏 + 右侧网页

---

## 免责

- 非 DeepSeek 官方产品，与深度求索公司无关。
- 不做支付自动化、不逆向订单接口、不代充。付款全程在官方页面完成。
- API Key 只存本机 `preferences`（`ds_shell`），除 `api.deepseek.com` 外不发送给任何人。
- 上游页面改版 / 改域名 / 改支付方式，壳子就可能失效——这类项目天生跟着上游走。

MIT License.
