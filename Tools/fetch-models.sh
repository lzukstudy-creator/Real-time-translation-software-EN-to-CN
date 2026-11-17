#!/bin/zsh
# 下载课译需要的模型权重（仓库里不含，每个约 650MB），并核对 SHA-256。
# 用法：zsh Tools/fetch-models.sh   （加 --refine 同时下载二次精确识别模型）
set -euo pipefail
root=${0:A:h:h}
cache="$HOME/Library/Caches/TingYi/models"
mkdir -p "$cache"

fetch() { # url sha256 file
    [[ -f "$cache/$3" ]] && [[ $(shasum -a 256 "$cache/$3" | cut -d' ' -f1) == "$2" ]] && return
    curl -L --fail -o "$cache/$3" "$1"
    [[ $(shasum -a 256 "$cache/$3" | cut -d' ' -f1) == "$2" ]] || { print "校验失败：$3"; exit 1; }
}

# 实时识别：NVIDIA Nemotron Speech Streaming English 0.6B（560ms, int8），sherpa-onnx 导出
manifest="$root/Resources/EnglishModel/model-manifest.json"
url=$(python3 -c "import json;print(json.load(open('$manifest'))['model_source'])")
sha=$(python3 -c "import json;print(json.load(open('$manifest'))['model_archive_sha256'])")
fetch "$url" "$sha" nemotron.tar.bz2
tmp=$(mktemp -d); tar -xjf "$cache/nemotron.tar.bz2" -C "$tmp"
for f in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx; do
    cp "$tmp"/*/"$f" "$root/Resources/EnglishModel/$f"
done
rm -rf "$tmp"
vad=$(python3 -c "import json;print(json.load(open('$manifest'))['vad']['source'])")
vadsha=$(python3 -c "import json;print(json.load(open('$manifest'))['vad']['sha256'])")
fetch "$vad" "$vadsha" silero_vad.onnx
cp "$cache/silero_vad.onnx" "$root/Resources/EnglishModel/silero_vad.onnx"
python3 - "$manifest" "$root/Resources/EnglishModel" <<'PY'
import hashlib, json, sys, pathlib
files = json.load(open(sys.argv[1]))["files"]
for name, sha in files.items():
    got = hashlib.sha256((pathlib.Path(sys.argv[2]) / name).read_bytes()).hexdigest()
    if got != sha: sys.exit(f"校验失败：{name}")
print("实时识别模型就绪")
PY

if [[ ${1:-} == --refine ]]; then
    # 二次精确识别：NVIDIA Parakeet TDT 0.6B v2（CC BY 4.0），sherpa-onnx int8 导出
    fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2" \
        6fc4426b54aa549a0019b8a75b8dea59164e71790a37ac56a045ad57f915f714 parakeet.tar.bz2
    mkdir -p "$root/Resources/RefineModel"
    tmp=$(mktemp -d); tar -xjf "$cache/parakeet.tar.bz2" -C "$tmp"
    cp "$tmp"/*/{encoder.int8.onnx,decoder.int8.onnx,joiner.int8.onnx,tokens.txt,README.md} "$root/Resources/RefineModel/"
    rm -rf "$tmp"
    print "二次精确识别模型就绪"
fi
