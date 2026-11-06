# 安全问题报告 / Security Policy

## 报告漏洞

请不要在公开的 Issue 里报告安全问题。

在本仓库的 **Security → Report a vulnerability** 页面私下提交（GitHub 私密漏洞报告）。请尽量写明：

- 受影响的版本和 macOS 版本
- 复现步骤或概念验证
- 你认为的影响，例如本地提权、读取他人流量、远程访问代理端口

一般会在 7 天内回复，修复后在 Release 说明里致谢（如果你愿意）。

## 范围

特别关注：

- 增强模式 (TUN) 的 root 启动脚本和 root 内核：本机其他程序是否能借此拿到 root 权限
- 内核控制接口 (REST API) 的访问控制
- 局域网共享的认证
- 解析不可信的订阅内容：崩溃、注入配置、读写本地文件

已知且写在 README「安全须知」里的局限不算漏洞，例如本机已有恶意程序时可以替换整个 app。

## Reporting a vulnerability

Please don't open a public issue. Use **Security → Report a vulnerability** on this repository
(GitHub private vulnerability reporting) and include the affected version, steps to reproduce and
the impact you see. You should hear back within 7 days.
