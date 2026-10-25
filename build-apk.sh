#!/bin/bash
# 构建 AI 助手 APK —— 手机端原生构建，严格对齐 AGP/Gradle 的构建步骤
#
# 对应标准 Gradle 构建的各个 task：
#   aapt2 compile  ->  processResources (资源编译)
#   aapt2 link     ->  linkResources (链接 + 生成 R.java)
#   javac          ->  compileDebugJavaWithJavac
#   d8 --lib       ->  dexBuilder / desugar
#   zipalign(真实) ->  zipAlign  (resources.arsc/.so 必须 4 字节对齐)
#   apksigner      ->  packageDebug (v1+v2+v3 签名)
#
# 与 AGP 的关键一致性点：
#   1. d8 必须带 --lib android.jar，否则平台类解析不出，desugaring 会生成错误字节码
#   2. resources.arsc 必须 STORED 且起始偏移 4 字节对齐，否则部分系统安装失败
#   3. minSdk/targetSdk 必须在 Manifest 与构建参数中一致
set -e
# ============ 配置区（按需修改）============
ROOT=${ROOT:-$HOME/androidbuild}            # 工具链根目录
PROJ=${PROJ:-$PWD}                          # Android 工程目录（含 AndroidManifest.xml）
OUT=${OUT:-/tmp/apk-build}                  # 中间产物（务必放 ext4，勿放 /sdcard）
MIN_SDK=${MIN_SDK:-21}
TARGET_SDK=${TARGET_SDK:-30}
KEYSTORE=${KEYSTORE:-$ROOT/keystore.jks}
KEYALIAS=${KEYALIAS:-androiddebugkey}
STOREPASS=${STOREPASS:-android}
# ==========================================

BT=$ROOT/android-14
AndroidJar=$(ls -d $ROOT/android-*/android.jar 2>/dev/null | head -1)
[ -f "$AndroidJar" ] || { echo "!! 找不到 android.jar，请放到 $ROOT/android-XX/android.jar"; exit 1; }
export JAVA_HOME=$(ls -d $ROOT/jdk-17*/ 2>/dev/null | head -1); export JAVA_HOME=${JAVA_HOME%/}
[ -x "$JAVA_HOME/bin/javac" ] || { echo "!! 找不到 JDK 17，请解压到 $ROOT/jdk-17.x.x/"; exit 1; }
export PATH=$JAVA_HOME/bin:$PATH
rm -rf "$OUT"; mkdir -p "$OUT/res" "$OUT/classes" "$OUT/dex" "$OUT/gen"

TU=$ROOT/termux/root/data/data/com.termux/files/usr
AAPT2="$TU/bin/aapt2"
[ -x "$AAPT2" ] || { echo "!! 找不到 aarch64 aapt2，请放到 $TU/bin/aapt2"; exit 1; }
# 注意：必须局部注入 LD_LIBRARY_PATH，全局 export 会让 javac/python 找不到 libc
aapt2() { LD_LIBRARY_PATH=$TU/lib "$AAPT2" "$@" 2>&1 | grep -v "linkerconfig" || true; }

echo "== 1. aapt2 compile（资源编译）=="
aapt2 compile --dir "$PROJ/res" -o "$OUT/res/resources.zip"

echo "== 2. aapt2 link（链接资源 + 生成 R.java）=="
aapt2 link \
  -o "$OUT/unsigned.apk" \
  -I "$AndroidJar" \
  --manifest "$PROJ/AndroidManifest.xml" \
  --java "$OUT/gen" \
  --min-sdk-version $MIN_SDK \
  --target-sdk-version $TARGET_SDK \
  --auto-add-overlay \
  "$OUT/res/resources.zip"
ls -la "$OUT/unsigned.apk"

echo "== 3. javac（编译 Java）=="
cp -r "$PROJ/assets" "$OUT/assets"
javac -source 8 -target 8 -encoding UTF-8 \
  -bootclasspath "$AndroidJar" \
  -d "$OUT/classes" \
  $(find "$PROJ/src" "$OUT/gen" -name "*.java") 2>&1 | grep -v "bootstrap class path" || true
find "$OUT/classes" -name "*.class" | sed 's/^/  /'

echo "== 4. d8 --lib（dex 转换，关键：必须传 --lib）=="
"$BT/d8" \
  --lib "$AndroidJar" \
  --min-api $MIN_SDK \
  --output "$OUT/dex" \
  $(find "$OUT/classes" -name "*.class") 2>&1 | grep -v "linkerconfig" | tail -5
ls -la "$OUT/dex"
[ -f "$OUT/dex/classes.dex" ] || { echo "!! classes.dex 未生成"; exit 1; }

echo "== 5. 组装（dex + assets 打入 APK）=="
python3 - "$OUT" <<'PY'
import zipfile, sys, os
out = sys.argv[1]
apk = os.path.join(out, 'unsigned.apk')
tmp = os.path.join(out, 'with_dex.apk')
zin = zipfile.ZipFile(apk, 'r')
zout = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
for item in zin.infolist():
    zout.writestr(item, zin.read(item.filename))
zout.write(os.path.join(out, 'dex', 'classes.dex'), 'classes.dex')
assets = os.path.join(out, 'assets')
for base, _, files in os.walk(assets):
    for f in files:
        full = os.path.join(base, f)
        zout.write(full, 'assets/' + os.path.relpath(full, assets).replace(os.sep, '/'))
zout.close(); zin.close()
os.replace(tmp, apk)
print('merged size=', os.path.getsize(apk))
PY

echo "== 6. zipalign（真实 4 字节对齐）=="
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 "$SCRIPT_DIR/zipalign.py" "$OUT/unsigned.apk" "$OUT/aligned.apk" \
  || { echo "!! 对齐失败，构建中止"; exit 1; }
ls -la "$OUT/aligned.apk"

echo "== 7. apksigner（v1+v2+v3 签名）=="
if [ ! -f "$KEYSTORE" ]; then
  echo "  生成调试证书: $KEYSTORE"
  keytool -genkeypair -v -keystore "$KEYSTORE" -storepass "$STOREPASS" -keypass "$STOREPASS" \
    -alias "$KEYALIAS" -keyalg RSA -keysize 2048 -validity 10950 \
    -dname "CN=Android Debug,O=Android,C=US" 2>&1 | tail -2
else
  # keystore 已存在：自动找出里面真正的 alias（避免 alias 不匹配导致签名失败）
  FOUND_ALIAS=$(keytool -list -keystore "$KEYSTORE" -storepass "$STOREPASS" 2>/dev/null \
                | awk -F, '/PrivateKeyEntry/{gsub(/^ +| +$/,"",$1); print $1; exit}')
  if [ -n "$FOUND_ALIAS" ] && [ "$FOUND_ALIAS" != "$KEYALIAS" ]; then
    echo "  keystore 中实际的 alias 是 '$FOUND_ALIAS'，已自动采用"
    KEYALIAS="$FOUND_ALIAS"
  fi
  [ -n "$FOUND_ALIAS" ] || { echo "!! keystore 里找不到私钥条目: $KEYSTORE"; exit 1; }
fi
APP_NAME=$(aapt2 dump packagename "$OUT/unsigned.apk" 2>/dev/null || echo app)
APK_OUT="$OUT/${APP_NAME##*.}.apk"
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$STOREPASS" --key-pass "pass:$STOREPASS" \
  --ks-key-alias "$KEYALIAS" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --min-sdk-version "$MIN_SDK" --max-sdk-version 34 \
  --out "$APK_OUT" "$OUT/aligned.apk" 2>&1 | grep -v linkerconfig || true

echo "== 8. 验证 =="
"$BT/apksigner" verify --verbose "$APK_OUT" 2>&1 | grep -v linkerconfig | head -6
echo "--- 包名 ---"
aapt2 dump packagename "$APK_OUT" 2>/dev/null || true
echo "--- zip 完整性 ---"
python3 - "$APK_OUT" <<'V'
import sys, zipfile, struct
p = sys.argv[1]
z = zipfile.ZipFile(p)
bad = z.testzip()
print('testzip:', bad if bad else 'OK')
for zi in z.infolist():
    if zi.filename.endswith(('.arsc', '.so')):
        with open(p, 'rb') as f:
            f.seek(zi.header_offset)
            h = f.read(30)
        nlen, elen = struct.unpack_from('<HH', h, 26)
        off = zi.header_offset + 30 + nlen + elen
        print(f'  {zi.filename} data@{off} mod4={off % 4} {"OK" if off % 4 == 0 else "FAIL"}')
V
ls -la "$APK_OUT"
