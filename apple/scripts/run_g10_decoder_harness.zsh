#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Requires an existing ffmpeg + libvpx installation. No downloads or installs.
readonly G10_DIR="${G10_DIR:-build/g10-validation}"
readonly VPX_PREFIX="${VPX_PREFIX:-/opt/homebrew}"
mkdir -p "$G10_DIR/fixtures" "$G10_DIR/results"
readonly FILTER="nullsrc=s=128x96:r=30:d=2,format=rgba,geq=r='mod(X+N*4,256)':g='mod(Y*2,256)':b=128:a='if(lt(X,W/3),0,if(lt(X,2*W/3),128,255))'"
ffmpeg -v error -f lavfi -i "$FILTER" -c:v libvpx-vp9 -pix_fmt yuva420p -g 30 -auto-alt-ref 0 -crf 20 -b:v 0 -threads 1 -y "$G10_DIR/fixtures/vp9-alpha.webm"
ffmpeg -v error -f lavfi -i "$FILTER" -c:v libvpx -pix_fmt yuva420p -g 30 -auto-alt-ref 0 -b:v 400k -threads 1 -y "$G10_DIR/fixtures/vp8-alpha.webm"
ffmpeg -v error -f lavfi -i "$FILTER" -c:v libvpx-vp9 -pix_fmt yuv420p -g 30 -crf 20 -b:v 0 -threads 1 -y "$G10_DIR/fixtures/vp9-opaque.webm"
ffmpeg -v error -f lavfi -i "$FILTER" -f lavfi -i "sine=frequency=440:duration=2" -c:v libvpx-vp9 -pix_fmt yuv420p -g 30 -crf 20 -b:v 0 -c:a libopus -threads 1 -y "$G10_DIR/fixtures/vp9-opus.webm"
ffmpeg -v error -f lavfi -i "$FILTER" -c:v libaom-av1 -pix_fmt yuv420p -cpu-used 8 -crf 40 -b:v 0 -threads 1 -y "$G10_DIR/fixtures/av1-opaque.webm"
ffmpeg -v error -f lavfi -i "$FILTER" -c:v libx264 -pix_fmt yuv420p -threads 1 -y "$G10_DIR/fixtures/h264-opaque.mp4"
ffmpeg -v error -f lavfi -i "$FILTER" -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le -threads 1 -y "$G10_DIR/fixtures/prores4444-alpha.mov"

clang -O2 -I"$VPX_PREFIX/include" -c scripts/g10_vpx_bridge.c -o "$G10_DIR/bridge.o"
swiftc -swift-version 6 -parse-as-library -import-objc-header scripts/g10_vpx_bridge.h \
    StreamCore/WebMContainer.swift scripts/g10_decoder_harness.swift "$G10_DIR/bridge.o" \
    -L"$VPX_PREFIX/lib" -lvpx -o "$G10_DIR/decoder"
typeset -a decoder_options=()
if [[ "${G10_REQUIRE_NATIVE_CONTROLS:-0}" == 1 ]]; then
    decoder_options+=(--require-native-controls)
fi
"$G10_DIR/decoder" "$G10_DIR/fixtures" "$G10_DIR/results" "${decoder_options[@]}" | tee "$G10_DIR/results.txt"
for codec in vp8 vp9; do
    decoder="libvpx"
    if [[ "$codec" == vp9 ]]; then decoder="libvpx-vp9"; fi
    ffmpeg -v error -c:v "$decoder" -i "$G10_DIR/fixtures/$codec-alpha.webm" \
        -vf 'select=eq(n\,30),alphaextract' -frames:v 1 -f rawvideo -pix_fmt gray \
        -y "$G10_DIR/results/reference-$codec.alpha"
    cmp "$G10_DIR/results/$codec-alpha.alpha" "$G10_DIR/results/reference-$codec.alpha"
    print "PASS: $codec alpha exactly matches FFmpeg"
done
