# 发布记录说明

`feature-release-notes.md` 用来记录对用户可感知的新功能、体验优化和重要修复。

`github/vX.Y.Z.md` 是 GitHub Release 的审核版英文正文。每次公开发版必须从 `github/TEMPLATE.md` 新建目标 tag 对应文件，并在打 tag 前运行 release notes 校验。

如果任务是“准备发版 / bump 版本 / 打 tag / 查 release 失败”，先读 `RELEASE_GUIDE.md`。

[pending-validation.md](pending-validation.md) 记录维护者批准留到发版后验证的项目，发布后按准确版本号联系报告者复测。

## 规则

- 按月份分组，格式使用 `## YYYY-MM`
- 同一个月份里，最新内容插在最上面
- 先写用户价值，再写变更摘要
- 不要把纯内部重构和实现噪音塞进来
- GitHub Release 正文默认使用审核过的英文，不直接使用 PR 标题自动生成

## 建议的列

- 日期
- 功能域
- 用户价值
- 变更摘要
