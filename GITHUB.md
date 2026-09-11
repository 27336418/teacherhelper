# 教师助手 — GitHub 发布与自动更新说明

> **当前状态（2026-09-11 16:45）**：仓库 `27336418/teacherhelper` 已创建且为公开仓库，
> 但里面还没有任何文件，所以应用点「检查更新」会提示「暂时没有可用的更新信息」。
> **只要按第四节「方式 A」在网页上传 `version.json` + `教师助手_v1.7.0.dmg` 两个文件，检查更新立刻生效**（不用 git、不用 Token）。
>
> 本次已为你做好的部分（无需再做）：
> - 本地 git 仓库已初始化，源码已提交到 `main` 分支
> - 远程已指向 `git@github.com:27336418/teacherhelper.git`
> - 应用内仓库地址已内置为 `27336418/teacherhelper`（v1.7.0）
> - 发布附件已生成：`教师助手_v1.7.0.dmg`（13 MB）
> - 更新清单模板已生成：`version.json`
> - 本机 SSH 密钥已生成：`~/.ssh/id_ed25519`（**尚未**加到 GitHub，所以 push 还需要第 1 步）

---

## 一、上传 GitHub（你只需做 3 步）

### 第 1 步：把 SSH 公钥加到 GitHub

公钥内容（本机 `~/.ssh/id_ed25519.pub`，私钥不要外传）：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPT3O513YNVn71NFfweeDYIOps0jmSUBTlSw23vlnVwT 27336418@163.com
```

打开 https://github.com/settings/keys → **New SSH key** → Title 随便写（如 `Mac 教师助手`）→ Key 粘贴上面整行 → **Add SSH key**。

> 不想用 SSH？也可以走 HTTPS：把下面的 `origin` 换成
> `https://github.com/27336418/teacherhelper.git`，push 时用户名填 `27336418`，
> 密码处粘贴 Personal Access Token（https://github.com/settings/tokens 生成，勾 `repo`）。

### 第 2 步：创建空仓库（已完成）

仓库 `27336418/teacherhelper` 已存在，无需再建。若以后要重建：https://github.com/new，
**Repository name** 填 `teacherhelper`、勾 **Public**、不要勾 README/.gitignore/license（本地已有内容）。

### 第 3 步：推送源码（终端粘一次）

```bash
cd /Users/a123/WorkBuddy/2026-09-07-11-19-53
git push -u origin main
```

看到 `branch 'main' set up to track 'origin/main'` 即成功。

---

## 二、发布第一个 Release（让「检查更新」生效）

### 方式 A：网页端（推荐，最直观）

1. 打开 https://github.com/27336418/teacherhelper/releases/new
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
   --repo 27336418/teacherhelper
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

## 四、应用内的检查更新逻辑（v1.7.0 起为双通道）

内置仓库：`27336418/teacherhelper`（写死在 `GitHubUpdateService.swift` 顶部，应用**没有**设置界面）

检查顺序（任一通道有数据即可检测到更新）：

1. **正式 Release**：`https://api.github.com/repos/27336418/teacherhelper/releases/latest`
   取 `tag_name`，优先用附件里的 `.dmg`
2. **仓库根目录的 `version.json`**（不需要创建 Release、不需要 Token）依次尝试：
   - `https://api.github.com/repos/.../contents/version.json?ref=main`（国内可直连）
   - `https://cdn.jsdelivr.net/gh/27336418/teacherhelper@main/version.json`（国内 CDN，快）
   - `https://raw.githubusercontent.com/...` （国内常被墙，作为最后兜底）
3. `GitHubRepoConfig.feedURL`（可选，任意 https 上的清单）

版本号用 **semver 数值**比较（`1.10.0 > 1.9.9` 不会误判）；

- 有新版本 → 自动下载安装包 → 打开 dmg，用户拖进「应用程序」即完成
- 下载地址会依次尝试：清单里的地址 → CDN → GitHub 加速镜像（ghproxy.net / gh-proxy.com / ghfast.top），
  因为国内网络直连 `github.com` 的 release 附件与 `raw.githubusercontent.com` 经常被墙
- 自动检查（启动 8 秒后）同一版本**每天只自动下载一次**；手动点「检查更新」才会弹提示

### 发布一次更新（方式 A：不用 git、不用 Token，推荐）

1. 浏览器打开 https://github.com/27336418/teacherhelper
2. **Add file → Upload files**，上传两个文件（模板就在项目文件夹里，直接拖进去）：
   - `version.json`：把 `version` 改成新版本号，`download` 改成新的 dmg 文件名
   - `教师助手_v<版本>.dmg`：`./make-dmg.sh` 生成的安装包（12MB 左右，网页上传限 25MB，够用）
3. 点 **Commit changes**，回到应用点「检查更新」即可看到新版本并自动下载

`version.json` 示例：

```json
{
  "version": "1.7.0",
  "download": "教师助手_v1.7.0.dmg",
  "notes": "本次更新内容"
}
```

- `download` 写相对文件名 → 自动解析成同仓库文件地址（走 jsDelivr CDN）
- 也可以直接写完整 https 链接（例如把 dmg 放到别处）

### 发布方式 B：正式 Release（需要 git/SSH 或 gh CLI）

```bash
gh release create v1.7.0 '教师助手_v1.7.0.dmg#教师助手 1.7.0' \
  --title '教师助手 v1.7.0' --notes-from-tag --repo 27336418/teacherhelper
```

> ⚠️ GitHub 未认证 API 限额 60 次/小时（按 IP 计）。返回 `HTTP 403 rate limit exceeded` 时稍后再试；
> 或在 `GitHubRepoConfig.token` 填个人访问令牌（只读 `public_repo` 即可），限额提至 5000 次/小时。
> 注意：如果限流，应用会自动改用 `version.json` 通道（jsDelivr 不计 GitHub 限额），所以不必担心。

### 验证链路

```bash
"/Users/a123/WorkBuddy/2026-09-07-11-19-53/教师助手.app/Contents/MacOS/ScheduleBar" --selftest-update
```

会打印：Release 接口状态、三条 `version.json` 通道的真实连通性、真实 JSON 的解析结果、
下载地址候选（含镜像），以及 semver 比较自测。

---

## 五、为什么不做「应用内自动更新」

- 菜单栏 App 进程运行时会占用 `.app`，LaunchServices 与进程目录关系不稳，跨版本覆盖易留缓存与状态错乱
- 打开下载页让用户自己覆盖安装更稳，也不会在启动时偷偷替换正在使用的程序

## 六、本地排查

```bash
grep 升级 ~/Library/Logs/教师助手.log
# 例：
# 升级：正在查询 27336418/teacherhelper 最新 release（auto=true）
# 升级：发现新版本 1.7.0（当前 1.6.0）→ https://github.com/...
# 升级：限流 HTTP 403
# 升级：404 27336418/teacherhelper      ← 仓库没建 / 没发 release
```
