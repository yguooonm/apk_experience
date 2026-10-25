# 在手机上从零构建 APK —— 踩坑实录与完整脚本

> 环境：无需电脑、无需 Android Studio、无需 Gradle。全程在 Android 手机上的
> Linux 容器里完成，产出可安装的正式 APK。

## 一、背景

目标：只用一个手机 App（WebView 套壳 HTML）实现一个小工具，打包成 APK 给别人装。

手机是华为鸿蒙（Android 12 兼容层），没有 root、没有 Shizuku、ADB 也没开。
所以「点一下 Android Studio 的 Run」这种路子完全走不通，
只能纯命令行手工搭一套等价于 AGP（Android Gradle Plugin）的构建链。

结果：中间踩了一连串坑，最后全部打通。下面是完整记录。

---

## 二、坑位清单（按踩坑顺序）

### 坑 0：SDCard 分区不支持原子写入

```
write: EINVAL: 无法原子发布文件
```

直接往 `/sdcard/xxx` 写文件失败。原因：该路径是 FUSE 挂载的，
不支持 O_TMPFILE / rename 语义的原子发布。

**解法**：所有中间产物放在 `/root/` 或 `/tmp/`（ext4），
只把最终 APK `cp` 到 `/sdcard/`。

---

### 坑 1：build-tools 是 x86 的，跑不了

从 `dl.google.com` 下的 `build-tools_r34-linux.zip`，解压后：

```
$ ./android-14/aapt
bash: ./aapt: cannot execute: required file not found
```

查 ELF 头发现是 `e_machine=62`（x86-64），手机是 aarch64。

**解法**：
- `aapt2` 改用 **Termux 仓库**的 aarch64 版本（`packages.termux.dev`）
- `d8` / `apksigner` 是 bash 脚本 + jar，**可以跨架构运行**，只要有 JRE
- `zipalign` 是原生二进制且只有 x86 版 → **自己用 Python 实现**（见坑 4）

```bash
# 拉 termux 的 aapt2 及依赖
curl -sfL -o aapt2.deb "https://packages.termux.dev/apt/termux-main/pool/main/a/aapt2/aapt2_16.0.0.4-4_aarch64.deb"
dpkg -x aapt2.deb root/
# 运行时要注入 termux 的库路径，否则报动态库找不到
LD_LIBRARY_PATH=$TU/lib $TU/bin/aapt2 version
```

---

### 坑 2：JDK 拆包安装后 java.security 报错

先试 `apt-get download openjdk-17-jdk-headless` 再 `dpkg -x` 拆包，
结果：

```
Exception in thread "main" java.lang.InternalError: Error loading java.security file
```

原因：拆包出来的 JDK 缺少 `/etc/java-17-openjdk/security/java.security`，
这个文件由 `openjdk-17-jre` 主包的 postinst 脚本生成。

**解法**：别用拆包，直接用 Adoptium 的完整 tarball：

```bash
curl -LO "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/aarch64/linux/OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.20.1_1.tar.gz"
tar xzf OpenJDK17U-*.tar.gz
```

下载地址里的版本号要用**实际存在**的那个（去目录列表里查），猜版本号会 404。

---

### 坑 3：`LD_LIBRARY_PATH` 污染全局 ← 极其隐蔽

```bash
export LD_LIBRARY_PATH=$TU/lib    # 为了让 aapt2 找到 termux 的 libc++
java -version
# java: error while loading shared libraries: /lib/aarch64-linux-gnu/libc.so: invalid ELF header
```

一开始以为 JDK 坏了，排查很久才发现：
Termux 的 `libc++` 等库把路径塞进全局 `LD_LIBRARY_PATH` 后，
连 `javac`、`python3` 都去找错了 libc。

**解法**：只在调用 aapt2 的那一条命令上局部注入：

```bash
# 错误
export LD_LIBRARY_PATH=$TU/lib
aapt2 compile ...

# 正确
LD_LIBRARY_PATH=$TU/lib "$AAPT2" compile ...
```

---

### 坑 4：d8 没有 `--lib` —— 构建能过，装上可能闪退

这是**最危险**的一个，因为构建不报错，日志里只有一行 warning：

```
Type `android.app.Activity` was not found, it is required for default or
static interface methods desugaring of `com.xxx.MainActivity`
```

原因：`d8` 不知道 `android.app.Activity` 是平台类，在做 desugaring 时
可能生成错误的字节码。

**解法**：加上 `--lib`，和 AGP 的行为一致：

```bash
d8 --lib "$ANDROID_JAR" --min-api 21 --output out/ $(find classes -name '*.class')
```

修复后那行 warning 会消失 —— **如果没消失，说明 `--lib` 没生效**。

---

### 坑 5：resources.arsc 从未对齐

```
apksigner: Malformed ZIP entry ... CRC-32 mismatch
# 或
Android 11+ 安装报「解析软件包时出现问题」
```

`targetSdk >= 30` 时，`resources.arsc` 必须：
1. 以 **STORED（不压缩）** 方式存储
2. 数据区起始偏移是 **4 的整数倍**

官方 `zipalign` 跑不了（x86），自己实现。踩的细节：

**（a）extra 字段长度不能死循环**

想通过插入 extra field 来补齐偏移，但 zip 的 extra 头固定 4 字节
（ID + len），如果要求 extra 总长必须是 4 的倍数，就会陷入死循环：

```python
# 死循环！pad=5 时 pad%4=1，每次 +4 永远不满足
while pad < 4 or pad % 4: pad += ALIGN
```

实际上 **zip 规范不要求 extra 总长是 4 的倍数**，
解析器按 `len(extra)` 读，只要内部每个 field 的 `4+len` 不超过总长即可。
所以 `pad` 可以取 4~7 之间的任意值：

```python
rem = base % ALIGN          # base = 无 extra 时数据区偏移
pad = ALIGN - rem           # 目标补齐量
while pad < 4:              # 至少 4 字节（extra 头本身）
    pad += ALIGN            # pad 落在 {4, 5, 6, 7}
extra = struct.pack('<HH', 0xD935, pad - 4) + b'\x00' * (pad - 4)
```

**（b）本地头字段别数错**

手写 zip 时最容易错的就是字段个数：

```python
# 本地文件头：sig,vneed,flag,method,time,date,crc,csize,usize,nlen,elen = 11 个
struct.pack('<IHHHHHIIIHH', 0x04034B50, 20, 0, method, t, d, crc,
            len(comp), len(data), len(nb), len(extra))

# 中央目录：sig,vmade,vneed,flag,method,time,date,crc,csize,usize,
#          nlen,elen,clen,disk,iattr,eattr,lho = 17 个
struct.pack('<IHHHHHHIIIHHHHHII', 0x02014B50, 20, 20, 0, method, t, d, crc,
            len(comp), len(data), len(nb), len(extra),
            0, 0, 0, 0o100644 << 16, header_offset)
```

漏一个参数就会 `struct.error: pack expected 11 items for packing (got 12)`，
或者更糟 —— 参数错位导致 CRC 写成别的值，签名时报
`CRC-32 mismatch between LFH and CD`。

**（c）写完必须回读校验**

```python
info = z.getinfo(name)
f.seek(info.header_offset)
hdr = f.read(30)
nlen, elen = struct.unpack_from('<HH', hdr, 26)
data_offset = info.header_offset + 30 + nlen + elen
assert data_offset % 4 == 0
```

---

### 坑 6：图标显示灰色、安装器不认

MT 管理器里 APK 是灰色文件图标，系统安装器提示「与系统不兼容」。

一度怀疑是鸿蒙特有的限制（网上确实有人说鸿蒙会拒非官方包），
但这个结论是**错的** —— 手机里其它正常安装的 APK 都是标准 Android 格式。

真正原因有两条：

1. **图标密度档位不全**：只放了 `mipmap-hdpi` 一档，
   MT 管理器按密度查找图标，找不到对应档位就显示灰色占位
2. **签名证书 DN 不规范**：`CN=xxx, OU=.., O=.., L=.., ST=.., C=..` 这种
   多字段写法部分解析器会出问题

**解法**：

```bash
# 五档密度全部生成：48/72/96/144/192 px
res/mipmap-mdpi/ic_launcher.png      # 48x48
res/mipmap-hdpi/ic_launcher.png      # 72x72
res/mipmap-xhdpi/ic_launcher.png     # 96x96
res/mipmap-xxhdpi/ic_launcher.png    # 144x144
res/mipmap-xxxhdpi/ic_launcher.png   # 192x192

# 签名用标准调试证书格式
keytool -genkeypair -keystore ks.jks -storepass android -keypass android \
  -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10950 \
  -dname "CN=Android Debug,O=Android,C=US"
```

---

### 坑 7：改了包名，但 dex 里还是旧的

这个坑**差点漏掉**。只改 `AndroidManifest.xml` 的 `package` 属性是不够的：

```
# 只改 Manifest
package: name='com.new.name'          ✅ 看起来对了
# 但 dex 里还是
com/old/name/MainActivity             ❌ 安装后点图标直接闪退
```

因为 Java 源码的 `package` 声明、编译产物的目录结构、
Manifest 里 `.MainActivity` 的相对类名展开，三者必须一致。

**解法**：三处一起改，并用工具验证：

```bash
# 1. 移动源码目录
mkdir -p src/com/new/name && mv src/com/old/path/MainActivity.java src/com/new/name/
# 2. 改 package 声明
sed -i 's/^package com\.old\.path;/package com.new.name;/' src/com/new/name/MainActivity.java
# 3. 改 Manifest
sed -i 's|package="com\.old\.path"|package="com.new.name"|' AndroidManifest.xml
```

验证：

```bash
aapt2 dump packagename app.apk                    # 看 Manifest 包名
python3 -c "
import zipfile,re
d = zipfile.ZipFile('app.apk').read('classes.dex')
print(sorted(set(re.findall(rb'com/new/name/[A-Za-z\$]+', d))))
print('旧包名残留:', b'com/old/path' in d)
"
```

---

## 三、最终构建流程

对应 AGP 的各个 task：

| 步骤 | 命令 | 对应 Gradle task |
|---|---|---|
| 资源编译 | `aapt2 compile --dir res -o res.zip` | `processResources` |
| 链接资源 | `aapt2 link -I android.jar --manifest ... --java gen/` | `linkResources` |
| 编译 Java | `javac -bootclasspath android.jar -d classes/` | `compileDebugJavaWithJavac` |
| dex 转换 | `d8 --lib android.jar --min-api 21` | `dexBuilder` |
| 对齐 | 自写 zipalign（见上） | `zipAlign` |
| 签名 | `apksigner sign --v1 --v2 --v3` | `packageDebug` |

完整脚本见同目录 `build-apk.sh` 和 `zipalign.py`。

### 环境准备清单

| 组件 | 来源 | 说明 |
|---|---|---|
| JDK 17 | Adoptium tarball（清华镜像） | 必须完整包，不能拆 deb |
| aapt2 | Termux 仓库 aarch64 | 需 `LD_LIBRARY_PATH` 局部注入 |
| d8 / apksigner | Google build-tools | bash 脚本 + jar，跨架构可用 |
| android.jar | `platform-34-ext12_r01.zip` | 只取其中的 android.jar |
| zipalign | 自己实现（Python） | 官方版只有 x86 |

### 关于 android.jar 的版本号

`dl.google.com/android/repository` 下的文件名带小版本号，
猜错就是 404。去 `repository2-3.xml` 里查实际文件名：

```bash
curl -sL "https://dl.google.com/android/repository/repository2-3.xml" -o repo.xml
grep -o 'platform-3[0-9][^<"]*\.zip' repo.xml | sort -u
```

---

## 四、验证清单（装之前一定要跑）

```bash
# 1. 签名有效
apksigner verify --verbose app.apk
#    → 应显示 v1/v2/v3 全部 true

# 2. zip 结构完整
python3 -c "import zipfile; print(zipfile.ZipFile('app.apk').testzip())"
#    → 无输出或 None

# 3. resources.arsc 已对齐
python3 zipalign.py app.apk /dev/null   # 或回读校验

# 4. 包名与 dex 一致（见坑 7）

# 5. Manifest 可解析
aapt2 dump badging app.apk | head -6
#    → package / minSdk / targetSdk / application-label 都正常
```

---

## 五、总结

真正卡住进度的不是「手机能不能做 APK」，而是**这些不会报错的静默失败**：

| 静默失败 | 表现 | 检测方法 |
|---|---|---|
| d8 缺 `--lib` | 构建成功，装上闪退 | 看 d8 警告里有没有 `Type ... was not found` |
| arsc 未对齐 | 构建成功，安装失败 | 回读数据区偏移 `% 4` |
| 图标缺档位 | APK 图标显示灰色 | `aapt2 dump badging` 看 `application-icon-*` |
| Manifest 与 dex 包名不一致 | 装上后点图标闪退 | 搜 dex 里的类路径 |
| extra 长度死循环 | 脚本卡住不退出 | 加超时 + 打印进度 |

教训：**手工拼 APK 时，每一步都要有可回读的校验，不能只看「命令没报错」。**

---

*完整可复用脚本：`build-apk.sh`（构建主流程）、`zipalign.py`（对齐实现）*
