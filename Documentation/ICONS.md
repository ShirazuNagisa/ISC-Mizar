# 应用图标与菜单栏图标

## 源文件

原始图放在各仓库的 `Sources/` 下（由设计给出，**JPEG、无 alpha**）：

| 文件 | 用途 |
|---|---|
| `Mizar-Light.jpeg` / `Mizar-Dark.jpeg` | Mizar 的浅色 / 深色应用图标 |
| `Phecda-Light.jpeg` / `Phecda-Dark.jpeg` | Phecda 的浅色 / 深色应用图标 |
| `Phecda-menubar.jpeg` | Phecda 的菜单栏图标 |

## 生成物

| 位置 | 内容 |
|---|---|
| `App/Mizar-iOS/Assets.xcassets/AppIcon.appiconset` | 1024px 亮 + 暗（`platform: ios` 与 `watchos` 两组） |
| `App/Mizar-watchOS/Assets.xcassets/AppIcon.appiconset` | 同上（两个 target 各一份，避免共享目录的成员归属问题） |
| `ISC-Phecda/Resources/Assets.xcassets/AppIcon.appiconset` | 16/32/128/256/512 × @1x/@2x，各含亮 + 暗 |
| `ISC-Phecda/Resources/Assets.xcassets/MenuBarIcon.imageset` | 18/36/54px，`template-rendering-intent: template` |

## 两个必须做对的地方

### 1. 应用图标不能有 alpha

iOS 会拒绝带透明通道的应用图标。源文件是 JPEG（本来就没有 alpha），
生成时统一 `convert('RGB')`。

### 2. 菜单栏图标必须是模板图

原图是**白色星形配近白背景**，而且右下角有「豆包AI生成」水印。

菜单栏图标靠 `template-rendering-intent` 让系统按菜单栏的明暗自动渲染成
黑或白。不设这一项的话，这个白色的图形在浅色菜单栏上会**完全看不见**。

提取方式（`Phecda-menubar.jpeg` 的亮度直方图很干净：背景 240–249，
星形 255）：

```python
alpha = clip((luminance - 250) / 5, 0, 1)   # 250 以下全透明 → 水印（176–240）自动消失
```

包围盒用**硬掩码的行列计数**算，不能用「有没有一个亮像素」——
JPEG 的背景渐变里散布着零星 >250 的噪点，而"任意一个像素"会被最角落的
那一颗撑满整幅图（实测裁出过负坐标）。

## ⚠️ macOS 的深色应用图标没有生效

`actool --platform macosx` **静默丢弃** `AppIcon` 的 `luminosity: dark`
变体：不报错、不警告，只产出一张合并的 `.icns`。同样的资源目录在
iOS 上产出 `UIAppearanceDark` 是正常的，所以格式本身没问题。

试过提高 `--minimum-deployment-target` 到 26.0，没有区别。

**因此：Phecda 目前只有浅色应用图标，深色变体待解决。**
Mizar（iOS / watchOS）的亮暗两套都已验证在 `Assets.car` 里。

排查方向：macOS 26 的深色图标可能要求 Icon Composer 的 `.icon` 格式，
而不是经典的 `appiconset`。
