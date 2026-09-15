# Dictionary 词典

一个 [Omarchy](https://omarchy.org/) 的 shell 插件（Quickshell / QML），把当前
选中的单词变成一条英汉词典释义，底层使用
[`sdcv`](https://github.com/Dushistov/sdcv) 和
[ECDICT](https://github.com/skywind3000/ECDICT) StarDict 词库。

在任意位置选中一个单词，按 `Ctrl+Shift+S`，即可在浮层中查看释义；也可以交互式
搜索、复制干净的词条，或把单词存入可直接导入 Anki 的生词本 —— 全程不需要终端弹窗。

```
┌─ 词典 ────────────────────────────────────── 查询 ─┐
│ 单词                                                │
│  ephemeral▏                                          │
│ ┌── 匹配 ─────────┐ ┌── 释义 ─────────────────────┐ │
│ │ ephemeral       │ │ ephemeral                    │ │
│ │ ECDICT          │ │ [ɪˈfemərəl]                  │ │
│ │ ephemerally     │ │ a. 短暂的, 朝生暮死的          │ │
│ │ ECDICT          │ │ n. 短命的东西                 │ │
│ └─────────────────┘ └──────────────────────────────┘ │
│      ↑/↓ 选择 · Enter 复制 · Ctrl+S 收藏 · Esc 关闭   │
└──────────────────────────────────────────────────────┘
```

## 功能

- **查询选中内容** —— 读取主选区（primary selection）或剪贴板中最近被触碰的那一个，
  并规整为单个查询词。
- **交互式搜索** —— `Ctrl+Shift+D` 打开空白输入框，边输入边查询（带防抖）。
- **逐级放宽匹配** —— 查询会自动升级：精确匹配 → 转小写后精确匹配 → 模糊建议，
  因此 `Ephemeral` 和 `ephemera` 都能得到有用的结果。
- **复制** —— `Enter` 复制「单词 + 音标 + 释义」的纯文本。
- **收藏到生词本** —— `Ctrl+S` 以 `单词<TAB>释义` 追加写入 TSV，可直接导入 Anki
  （换行以 `<br>` 保存）。
- **感知最近来源** —— 若安装了共享的 `omarchy-dict` 辅助脚本，本插件会与
  `dict-*` 脚本对「选区还是剪贴板被最后使用」保持一致。

## 依赖

本插件属于第三方代码，在 Omarchy shell 进程中以你的用户权限**非沙箱**运行。它需要
以下命令存在于 `PATH` 中：

| 依赖 | 用途 | 来源 |
| --- | --- | --- |
| `sdcv` | 执行查询的 StarDict 命令行客户端 | `extra/sdcv` |
| `stardict-ecdict` | 英汉 ECDICT 词库数据 | AUR |
| `wl-clipboard` | `wl-copy` / `wl-paste`，用于读取选区和复制 | `extra/wl-clipboard` |
| `bash`、coreutils | 运行 `selection.sh`、写入生词本 | 基础包 |
| `omarchy-notification-send` | 保存 / 无结果通知 | Omarchy |

```sh
sudo pacman -S sdcv wl-clipboard
yay -S stardict-ecdict      # AUR
```

`sdcv` 会自动在 `/usr/share/stardict/dic/` 下找到词库。安装插件前先确认它可用：

```sh
sdcv -n -j -e ephemeral
```

## 安装

### 使用 Omarchy 插件 CLI（推荐）

```sh
omarchy plugin add https://github.com/NonMirror/nonmirror.dict --enable
```

该命令会克隆仓库、校验 manifest、安装到
`~/.config/omarchy/plugins/nonmirror.dict/` 并启用。

### 手动安装

```sh
git clone https://github.com/NonMirror/nonmirror.dict \
  ~/.config/omarchy/plugins/nonmirror.dict
```

然后在 `~/.config/omarchy/shell.json` 的 `plugins` 中加入：

```json
"plugins": [
  { "id": "nonmirror.dict" }
]
```

保存 `shell.json` 后 shell 会自动热重载；如未生效，用
`omarchy-shell shell rescanPlugins` 强制重新发现。

### 快捷键

在 `~/.config/hypr/bindings.lua` 中绑定：

```lua
o.bind("CTRL + SHIFT + S", "词典：查询选中内容",
  "omarchy-shell shell toggle nonmirror.dict '{\"mode\":\"lookup\"}'")
o.bind("CTRL + SHIFT + D", "词典：搜索",
  "omarchy-shell shell toggle nonmirror.dict '{\"mode\":\"search\"}'")
o.bind("CTRL + SHIFT + ALT + S", "词典：收藏到生词本",
  "omarchy-shell shell summon nonmirror.dict '{\"mode\":\"save\"}'")
```

然后重载：

```sh
hyprctl reload
```

> **注意：** 在合成器层面绑定 `Ctrl+Shift+S` / `Ctrl+Shift+D` 会在应用获得焦点时
> 遮蔽这两个组合键。如有影响，请改用其他快捷键。

## 卸载

### 使用 Omarchy 插件 CLI（推荐）

```sh
omarchy plugin remove nonmirror.dict
```

### 手动卸载

```sh
omarchy plugin disable nonmirror.dict
rm -rf ~/.config/omarchy/plugins/nonmirror.dict
omarchy-shell shell rescanPlugins
```

再从 `~/.config/omarchy/shell.json` 中删除 `nonmirror.dict` 条目，并从
`~/.config/hypr/bindings.lua` 中删除上面的三个绑定。

插件不会在生词本之外创建任何状态，因此没有其他残留。如需连同生词本一起删除：

```sh
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-dict/vocab.tsv"
```

## 使用

| 按键 | 操作 |
| --- | --- |
| `Ctrl+Shift+S` | 查询当前选区 / 剪贴板 |
| `Ctrl+Shift+D` | 打开空白搜索框 |
| `Ctrl+Shift+Alt+S` | 查询选中内容并收藏到生词本 |
| 直接输入 | 编辑搜索框（防抖后自动查询） |
| `↑` / `↓`、`Alt+J` / `Alt+K` | 在匹配结果间移动 |
| `Enter` | 复制当前词条（若无结果则重新查询） |
| `Ctrl+S` | 将当前词条收藏到生词本 |
| `Ctrl+V` | 把剪贴板内容粘贴到搜索框 |
| `Backspace`、`Ctrl+Backspace`、`Ctrl+U` | 编辑输入框 |
| `Ctrl+Del` | 清空输入框 |
| 点击匹配项 | 选中该项 |
| `Esc` / 点击外部 | 关闭浮层 |

复制和收藏会在标题栏显示一条简短状态，并通过 `omarchy-notification-send` 发送通知
（重复操作会覆盖旧通知，不会堆积）。

### 调用模式

也可以直接驱动插件，快捷键绑定的就是这些命令：

```sh
# 查询选区 / 剪贴板
omarchy-shell shell toggle nonmirror.dict '{"mode":"lookup"}'

# 打开空白搜索框
omarchy-shell shell toggle nonmirror.dict '{"mode":"search"}'

# 查询选中内容并收藏
omarchy-shell shell summon nonmirror.dict '{"mode":"save"}'

# 查询指定单词
omarchy-shell shell toggle nonmirror.dict '{"mode":"lookup","term":"ephemeral"}'
```

## 生词本 / Anki

收藏的单词写入以下制表符分隔文件：

```
${XDG_DATA_HOME:-~/.local/share}/omarchy-dict/vocab.tsv
```

每行格式为 `单词<TAB>释义`，换行以 `<br>` 表示、HTML 实体已转义，与
`~/.local/bin/dict-save` 和 `omarchy-dict` 辅助脚本保持一致，因此已有的导入流程
可以继续使用。

在 Anki 中：**文件 → 导入**，选择 `vocab.tsv`，字段分隔符设为 **Tab**，并勾选
**允许字段中使用 HTML**。这样释义中的 `<br>` 会渲染为换行，而不是字面文本。

## 实现原理

- `Dict.qml` 负责浮层、按键处理与 `sdcv` 调用。查询严格串行：在上一次查询未完成时
  输入的新词会被暂存，等当前查询结束后再执行，因此过期结果不会覆盖新结果。
- `sdcv -n -j` 返回 JSON，QML 直接解析。精确匹配阶段会加上 `-e`；模糊建议会重新
  排序，让你查询的词被选中，而不是排到最后。
- `selection.sh` 输出要查询的词。若存在共享的
  `${XDG_DATA_HOME:-~/.local/share}/omarchy-dict/lib.sh`，则复用它（包含
  `dict-watch` 记录的主选区 / 剪贴板时间戳）；否则退化为「优先主选区，其次剪贴板」。
- 插件是自包含的。`~/.local/bin/dict-*` 脚本和 `omarchy-dict/lib.sh` 都是可选的，
  只有「最近来源」这一判断会用到它们。

## 开发

提交前先校验：

```sh
omarchy plugin validate ~/.config/omarchy/plugins/nonmirror.dict
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/nonmirror.dict/Dict.qml
```

`~/.config/omarchy/plugins/` 下的改动会自动重载；可用
`omarchy-shell shell rescanPlugins` 强制重新发现。

## 注意事项与限制

- 词库为**英译汉**；如需其他语言，请安装 `sdcv` 能识别的其他 StarDict 词库。
- 浮层打开时会独占键盘（`WlrKeyboardFocus.Exclusive`），在关闭前上述之外的合成器
  快捷键不可用。
- `selection.sh` 会取选区第一行并去掉首尾标点；只有在存在共享的 `omarchy-dict`
  辅助脚本时，多词选区才会退化为其中最长的单词。
- 生词本在插件侧是只追加的；如需去重请手动编辑。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
