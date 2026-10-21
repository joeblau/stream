#!/bin/zsh
set -euo pipefail
readonly SCRIPT_DIR=${0:A:h}
export STREAM_INTERVIEW_RETURN_DIR="${STREAM_INTERVIEW_RETURN_DIR:-${SCRIPT_DIR:h}/build/native-interview-return-video-validation}"
export STREAM_INTERVIEW_RETURN_CLI_SOURCE=native_interview_return_video_cli.swift
export STREAM_INTERVIEW_RETURN_BROWSER_SCRIPT=native-interview-return-video-browser.mjs
export STREAM_INTERVIEW_RETURN_VIDEO_VALIDATION=1
exec zsh "$SCRIPT_DIR/run_native_interview_return_audio_harness.zsh" "$@"
