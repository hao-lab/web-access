# web-access Headless 服务器适配说明

> 记录时间：2026-05-21  
> 本地工作目录：`/tmp/web-access-headless`  
> Fork 仓库：`https://github.com/hao-lab/web-access`  
> 目标环境：Amazon Linux 2023，无 X11 / Wayland / GUI 的 headless 服务器

## 1. 背景与目标

原版 `eze-is/web-access` 的核心设计假设是：

1. 用户本机已经有一个日常使用的桌面 Chrome / Chromium；
2. 这个浏览器已经登录过目标网站；
3. `web-access` 通过 Chrome DevTools Protocol 连接该浏览器，从而复用已有登录态；
4. Agent 通过 HTTP API 控制浏览器页面。

在当前服务器环境中，这些假设不成立：

- 服务器没有图形桌面；
- 没有本地可手动操作的 Chrome 窗口；
- headless Chrome 默认 profile 是空的；
- 登录态、Cookie、localStorage 都需要显式管理；
- Hermes `agent-browser` 同一个 session 内多 tab 操作会排队，不能满足真正并行的需求。

本次 fork 的目标是：

- 让 `web-access` 能在无 GUI/headless 服务器上运行；
- 使用 Playwright 已安装的 Chromium / `chrome-headless-shell`；
- 通过 CDP target/session 机制实现多 tab 并行控制；
- 提供可控的进程生命周期管理；
- 为需要登录的网站提供 Cookie / profile 复用能力。

---

## 2. 当前改动概览

截至当前记录，主要提交如下：

```text
5bae4ef feat: add cookie import/export support for headless sessions
e118b4e feat: add unified headless-browser.sh wrapper for lifecycle management
7720e24 feat: switch to headless_shell as default browser for server env
f2cf83c feat: support headless Chrome via fallback WebSocket URL resolution
7af34af fix(v2.5.3): /new and /navigate accept URL via POST body
```

核心改动文件：

```text
scripts/cdp-proxy.mjs
scripts/headless-browser.sh
scripts/start-headless.sh
scripts/cookie-manager.mjs
```

---

## 3. Headless Chrome WebSocket 地址修复

### 问题

原版 `cdp-proxy.mjs` 在无头模式下容易连不上 Chrome。

原因是 `chrome-headless-shell` 的浏览器级 WebSocket 地址包含 UUID，例如：

```text
ws://127.0.0.1:9222/devtools/browser/<uuid>
```

不能简单假设路径是：

```text
/devtools/browser
```

### 解决

在 `scripts/cdp-proxy.mjs` 中增加 fallback WebSocket 解析逻辑：

1. 访问：

```text
http://127.0.0.1:9222/json/version
```

2. 读取返回 JSON 中的：

```json
webSocketDebuggerUrl
```

3. 从中解析真实 WebSocket path。

这样可以稳定连接 `chrome-headless-shell`。

---

## 4. 浏览器二进制选择

当前默认选择：

```bash
/root/.cache/ms-playwright/chromium_headless_shell-1217/chrome-headless-shell-linux64/chrome-headless-shell
```

而不是完整 Chromium：

```bash
/root/.cache/ms-playwright/chromium-1217/chrome-linux64/chrome
```

原因：

- `chrome-headless-shell` 更轻量；
- 对导航、JS 执行、截图、CDP target/session 控制足够；
- 内存占用低于完整 Chromium；
- 更适合服务器自动化任务。

如遇到需要 WebGL、复杂媒体能力、真实窗口行为的网站，可以再切回完整 Chromium。

---

## 5. 统一生命周期管理脚本

新增：

```bash
scripts/headless-browser.sh
```

常用命令：

```bash
./scripts/headless-browser.sh start
./scripts/headless-browser.sh stop
./scripts/headless-browser.sh restart
./scripts/headless-browser.sh status
./scripts/headless-browser.sh logs all
```

该脚本负责同时管理：

1. `chrome-headless-shell`；
2. `scripts/cdp-proxy.mjs`。

关键点：

- 使用 `setsid` 启动 Chrome；
- 记录 PID / PGID；
- 停止时通过 `kill -- -PGID` 清理整个 Chrome 进程组；
- 避免 renderer / utility 子进程残留；
- 等待 `9222` 和 `3456` 端口就绪。

默认端口：

```text
Chrome CDP: 127.0.0.1:9222
cdp-proxy: 127.0.0.1:3456
```

建议保持只监听本机地址，不要暴露公网。

---

## 6. 并行能力验证

本次 fork 的核心价值之一是绕过 `agent-browser` 的同 session 串行队列。

已完成测试包括：

1. 单 tab 完整链路：
   - `new`
   - `navigate`
   - `info`
   - `eval`
   - `screenshot`
   - `close`

2. 多 tab 并行：
   - 多个 tab 同时创建；
   - 多个 tab 同时执行 `info`；
   - 多个 tab 同时执行 `eval`；
   - 多个 tab 同时截图。

3. 边界情况：
   - 无效 target；
   - 空 body；
   - 重复 close；
   - proxy 重启后重新创建 tab。

验证结果：

```text
30 个测试项全部通过
10 tab 并行截图约 0.22s
```

结论：

- 基于 CDP target/session 的并行控制路径成立；
- 在 headless 服务器上可以真正实现多 tab 并发；
- 比通过 `agent-browser` 同 session 队列逐个操作更适合高并发抓取/截图/页面评估任务。

---

## 7. 登录态问题分析

### 原版 web-access 的登录态来源

原版通常依赖用户本机桌面浏览器已经登录。

也就是说，它不是自己登录，而是复用已有浏览器 profile 中的：

- Cookie；
- localStorage；
- sessionStorage；
- IndexedDB；
- 浏览器设备状态。

### Headless 服务器的问题

当前服务器上的 `chrome-headless-shell` 默认 profile 是空的。

已经验证初始状态：

```text
0 cookies
```

所以无头模式不会自动拥有任何网站登录态。

必须显式处理登录状态。

---

## 8. 已实现：Cookie 导入/导出

新增端点：

```http
GET  /cookies/get
POST /cookies/set
```

新增工具：

```bash
scripts/cookie-manager.mjs
```

支持命令：

```bash
node scripts/cookie-manager.mjs import cookies.json
node scripts/cookie-manager.mjs export storage-state.json
node scripts/cookie-manager.mjs list
node scripts/cookie-manager.mjs inject example.com session abc123
```

支持导入格式：

1. 浏览器插件导出的 Cookie JSON；
2. Playwright `storageState` 中的 `cookies` 部分。

### 验证结果

测试站点：

```text
https://httpbin.org/cookies
```

注入 Cookie：

```json
{
  "name": "test_session",
  "value": "abc123",
  "domain": "httpbin.org",
  "path": "/",
  "secure": true,
  "httpOnly": false
}
```

页面返回：

```json
{
  "cookies": {
    "test_session": "abc123"
  }
}
```

说明 Cookie 已经成功注入并随请求发送。

---

## 9. 推荐登录态策略

### 9.1 Cookie / storageState 导入

适合：

- 普通网站；
- 内部系统；
- Cookie 有较长有效期的网站；
- 不强绑定设备指纹的网站。

典型流程：

```bash
cd /tmp/web-access-headless
./scripts/headless-browser.sh start
node scripts/cookie-manager.mjs import /tmp/cookies.json
curl -s -X POST --data-raw 'https://target-site.com' http://127.0.0.1:3456/new
```

限制：

- Cookie 过期后需要重新导入；
- 对 localStorage / IndexedDB 依赖重的网站不一定够；
- 强风控网站可能失效。

### 9.2 持久 profile

建议对需要长期复用登录态的网站使用独立 profile：

```bash
USER_DATA_DIR=/root/browser-profiles/target-site ./scripts/headless-browser.sh start
```

这样 Cookie、localStorage、IndexedDB 等浏览器状态可以跨重启保留。

建议一站一 profile：

```text
/root/browser-profiles/site-a
/root/browser-profiles/site-b
/root/browser-profiles/notion
/root/browser-profiles/github
```

避免不同网站状态混杂。

### 9.3 SSH 隧道连接远端 CDP 手动登录

可以从本机通过 SSH 隧道连接服务器上的 headless Chrome：

```bash
ssh -N \
  -L 9222:127.0.0.1:9222 \
  -L 3456:127.0.0.1:3456 \
  root@服务器IP
```

本机访问：

```text
http://127.0.0.1:9222/json/list
```

创建远端页面：

```bash
curl -s -X POST --data-raw 'https://目标网站.com/login' http://127.0.0.1:3456/new
```

然后点击 `/json/list` 中的 `devtoolsFrontendUrl`，通过本机 Chrome DevTools 连接远端 headless 页面并尝试登录。

适合：

- 普通账号密码登录；
- 短信/邮箱验证码；
- 部分二维码登录。

不稳定或不适合：

- 滑块验证码；
- Passkey / WebAuthn；
- 强设备指纹；
- 需要真实 GUI 窗口事件的网站。

### 9.4 noVNC / Xvfb 一次性登录

如果 DevTools 远程调试体验不够，需要后续考虑临时使用：

```text
Xvfb + full Chromium + noVNC
```

完成一次真正图形化登录后，保存同一个 `user-data-dir`，后续再无头复用。

这个方案成功率最高，但组件更重，不建议作为第一选择。

---

## 10. 还未完成 / 后续可做

### 10.1 localStorage 注入

当前 `cookie-manager.mjs` 主要完成 Cookie 导入/导出。

Playwright `storageState` 的结构中还可能包含：

```json
{
  "origins": [
    {
      "origin": "https://example.com",
      "localStorage": [
        { "name": "token", "value": "..." }
      ]
    }
  ]
}
```

后续可以增强为：

- 创建对应 origin 的临时 tab；
- 导航到该 origin；
- 执行 JS 写入 localStorage；
- 再关闭临时 tab。

### 10.2 profile 参数封装

目前可以通过环境变量：

```bash
USER_DATA_DIR=/root/browser-profiles/site ./scripts/headless-browser.sh start
```

后续可以封装为：

```bash
./scripts/headless-browser.sh start --profile site
./scripts/headless-browser.sh stop --profile site
./scripts/headless-browser.sh status --profile site
```

### 10.3 一次性登录命令

后续可设计：

```bash
./scripts/headless-browser.sh login --profile site
```

内部根据环境选择：

1. DevTools tunnel 指引；
2. noVNC / Xvfb；
3. 本机 Chrome 反向 CDP 隧道。

### 10.4 文档与安全说明

建议继续补 README：

- headless server usage；
- cookie-manager usage；
- profile management；
- SSH tunnel login；
- 不要提交 Cookie / profile；
- 不要把 CDP / proxy 端口暴露公网。

---

## 11. 安全注意事项

- CDP 端口权限极高，等价于完整控制浏览器；
- `9222` 和 `3456` 应只监听 `127.0.0.1`；
- 如需远程访问，优先使用 SSH tunnel；
- Cookie 文件、Playwright storageState、Chrome profile 都等价于登录凭证；
- 不要将这些文件提交到 git；
- 不要在日志或 issue 中粘贴真实 Cookie / token / API Key；
- 所有 API Key 输出必须脱敏为 `[REDACTED]`。

---

## 12. 当前建议下一步

如果继续推进，建议顺序：

1. 检查当前进程状态：

```bash
cd /tmp/web-access-headless
./scripts/headless-browser.sh status
```

2. 重新跑一次回归测试，确认 handoff 后环境仍一致；
3. 增强 `cookie-manager.mjs` 支持 localStorage 注入；
4. 增强 `headless-browser.sh` 支持 `--profile` 参数；
5. 补 README 文档；
6. 全量测试通过后再提交。

---

## 13. 一句话总结

当前 fork 已经把 `web-access` 从桌面浏览器依赖型工具，改造成了可以在 Amazon Linux 2023 无头服务器上运行的轻量级、多 tab 并行 CDP proxy，并初步解决了无头登录态问题。后续重点是从 Cookie 注入扩展到 localStorage / 持久 profile / 一次性人工登录工作流。
