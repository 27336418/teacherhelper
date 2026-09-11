# 教师助手 — GitHub 发布与自动更新说明

> 本次已为你做好的部分（无需再做）：
> - 本地 git 仓库已初始化，源码已提交到 `main` 分支（72 个文件，`.app`/`.dmg`/`.build` 已排除）
> - 远程已指向 `git@github.com:27336418/teacher-helper.git`
> - 应用内仓库地址已内置为 `27336418/teacher-helper` 并重新打包
> - 发布附件已生成：`教师助手_v1.6.0.dmg`（12 MB）
> - 本机 SSH 密钥已生成：`~/.ssh/id_ed25519`

---

## 一、上传 GitHub（你只需做 3 步）

### 第 1 步：把 SSH 公钥加到 GitHub

公钥内容（本机 `~/.ssh/id_ed25519.pub`，私钥不要外传）：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPT3O513YNVn71NFfweeDYIOps0jmSUBTlSw23vlnVwT 27336418@163.com
```

打开 https://github.com/settings/keys → **New SSH key** → Title 随便写（如 `Mac 教师助手`）→ Key 粘贴上面整行 → **Add SSH key**。

> 不想用 SSH？也可以走 HTTPS：把下面的 `origin` 换成
> `https://github.com/27336418/teacher-helper.git`，push 时用户名填 `27336418`，
> 密码处粘贴 Personal Access Token（https://github.com/settings/tokens 生成，勾 `repo`）。

### 第 2 步：创建空仓库

打开 https://github.com/new

- **Repository name**：`teacher-helper`
- **Public** ✔
- **不要**勾 Add a README file / .gitignore / license（本地已有内容）
- 点 **Create repository**

### 第 3 步：推送源码（终端粘一次）

```bash
cd /Users/a123/WorkBuddy/2026-09-07-11-19-53
git push -u origin main
```

看到 `branch 'main' set up to track 'origin/main'` 即成功。

---

## 二、发布第一个 Release（让「检查更新」生效）

### 方式 A：网页端（推荐，最直观）

1. 打开 https://github.com/27336418/teacher-helper/releases/new
2. **Choose a tag** 输入 `v1.6.0` → 点 `Create new tag: v1.6.0 on publish`
3. **Release title**：`教师助手 v1.6.0`
4. 描述里写更新说明（可留空）
5. **Attach binaries** 上传：`/Users/a123/WorkBuddy/2026-09-07-11-19-53/教师助手_v1.6.0.dmg`
6. 点 **Publish release**

### 方式 B：命令行（装了 GitHub CLI 后）

```bash
cd /Users/a123/WorkBuddy/2026-09-07-11-19-53
gh release create v1.6.0 "教师助手_v1.6.0.dmg#教师助手 1.6.0" \
   --title "教师助手 v1.6.0" \
   --notes "首个公开版本：课表 / 延时监考 / 工位 / 座位 / 校历 / 提醒，支持在线检查更新" \
   --repo 27336418/teacher-helper
```

---

## 三、以后每发一次新版（3 条命令）

```bash
cd /Users/a123/WorkBuddy/2026-09-07-11-19-53

# 1) 改版本号（Info.plist 两个字段，CFBundleVersion 递增）
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.7.0" ScheduleBar/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 33" ScheduleBar/Info.plist

# 2) 重新编译 + 打包 dmg（详见 ~/.workbuddy/skills/macos-menubar-app-build）
VERSION=1.7.0 ./make-dmg.sh

# 3) 提交并推送源码，再去网页发 release 上传 dmg
git add -A && git commit -m "v1.7.0：<本次改动>"
git push
```

---

## 四、应用内的检查更新逻辑

- 内置仓库：`27336418/teacher-helper`（写死在 `GitHubUpdateService.swift` 顶部，应用**没有**设置界面）
- 调 `https://api.github.com/repos/27336418/teacher-helper/releases/latest`
- 取 `tag_name`（如 `v1.6.0`）与本地 `Info.plist` 的 `CFBundleShortVersionString` 做 **semver 数值**比较（`1.10.0 > 1.9.9` 不会误判）
- 有新版本 → **直接打开下载地址**，用户自行决定是否下载
- 自动检查（启动 8 秒后）同一版本**每天只自动打开一次**，不会每次启动都弹浏览器
- 未配置 / 网络失败 / 限流：自动检查静默（只写日志），手动点侧边栏「检查更新」才提示原因

### 验证链路

```bash
# 仓库和 release 都建好之后（未建好会返回 404，属正常）
/Applications/教师助手.app/Contents/MacOS/ScheduleBar --selftest-update
# 也可拿别人的公开仓库测网络：--selftest-update sparkle-project/Sparkle
```

会打印：HTTP 状态、tag_name、assets，以及 semver 比较自测结果。

> ⚠️ GitHub 未认证 API 限额 60 次/小时（按 IP 计）。返回 `HTTP 403 rate limit exceeded` 时稍后再试；
> 或在 `GitHubRepoConfig.token` 填个人访问令牌（只读 `public_repo` 即可），限额提至 5000 次/小时。
> 个人日常使用（每天检查几次）不会触发限流。

---

## 五、为什么不做「应用内自动更新」

- 菜单栏 App 进程运行时会占用 `.app`，LaunchServices 与进程目录关系不稳，跨版本覆盖易留缓存与状态错乱
- 打开下载页让用户自己覆盖安装更稳，也不会在启动时偷偷替换正在使用的程序

## 六、本地排查

```bash
grep 升级 ~/Library/Logs/教师助手.log
# 例：
# 升级：正在查询 27336418/teacher-helper 最新 release（auto=true）
# 升级：发现新版本 1.7.0（当前 1.6.0）→ https://github.com/...
# 升级：限流 HTTP 403
# 升级：404 27336418/teacher-helper      ← 仓库没建 / 没发 release
```
