#!/bin/zsh
set -euo pipefail

task_root=${0:A:h}
task_output=${1:-"$task_root/dist"}
task_app="$task_output/课译.app"
task_cache="$task_root/.build-cache"
task_vendor="$task_root/Vendor/Sherpa"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Frameworks" \
    "$task_app/Contents/Resources/EnglishModel" "$task_app/Contents/Resources/RefineModel" "$task_cache"
cp "$task_root/Info.plist" "$task_app/Contents/Info.plist"
CLANG_MODULE_CACHE_PATH="$task_cache" xcrun swiftc -O -swift-version 5 \
    -module-cache-path "$task_cache" -target x86_64-apple-macos26.0 \
    -import-objc-header "$task_vendor/c-api.h" \
    -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
    -framework SwiftUI -framework Translation \
    -L "$task_vendor" -l sherpa-onnx-c-api \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    "$task_root"/Sources/*.swift -o "$task_app/Contents/MacOS/TingYi"
cp -c "$task_root"/Resources/EnglishModel/* "$task_app/Contents/Resources/EnglishModel/"
# 二次精确识别模型：NVIDIA Parakeet TDT 0.6B v2（CC BY 4.0），sherpa-onnx int8 导出（约 660MB）。
# 已下载（Tools/fetch-models.sh --refine）就自动打包；TINGYI_REFINE=0 ./build.sh 可不带。
task_refine="$task_root/Resources/RefineModel"
if [[ ${TINGYI_REFINE:-auto} != 0 && -f "$task_refine/encoder.int8.onnx" ]]; then
    for task_file in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
        cp -c "$task_refine/$task_file" "$task_app/Contents/Resources/RefineModel/"
    done
    # 二次识别也用专业词加权，需要由 tokens.txt 按固定格式生成的 bpe.vocab（“词片<TAB>-1.0”）。
    awk '{t=$0; sub(/ [0-9]+$/,"",t); printf "%s\t-1.0\n", t}' "$task_refine/tokens.txt" \
        > "$task_app/Contents/Resources/RefineModel/bpe.vocab"
elif [[ ${TINGYI_REFINE:-auto} == 1 ]]; then
    echo "找不到二次精确识别模型，请先运行 zsh Tools/fetch-models.sh --refine" >&2
    exit 1
fi
# 课件词表是个人资料，不在公开仓库里；没有时使用空的示例词表（内置通用技术术语仍然可用）
if [[ -f "$task_root/Resources/coursepack.json" ]]; then
    cp "$task_root/Resources/coursepack.json" "$task_app/Contents/Resources/coursepack.json"
else
    cp "$task_root/Resources/coursepack.sample.json" "$task_app/Contents/Resources/coursepack.json"
fi
cp "$task_root/Resources/technical-terms.tsv" "$task_app/Contents/Resources/technical-terms.tsv"
cp "$task_root/Resources/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
cp -R "$task_root/Resources/Licenses" "$task_app/Contents/Resources/"
cp "$task_vendor"/*.dylib "$task_app/Contents/Frameworks/"
for task_library in "$task_app/Contents/Frameworks/"*.dylib; do
    codesign --force --sign - "$task_library"
done
codesign --force --sign - --identifier app.tingyi.live "$task_app"
codesign --verify --deep --strict "$task_app"
print "Built: $task_app"
