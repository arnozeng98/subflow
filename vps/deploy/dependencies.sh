#!/usr/bin/env bash
# 本文件由 scripts/gen_dependencies.py 依据 configs/dependencies.lock.json 自动生成，请勿手改。
WRANGLER_VERSION="4.48.0"
WRANGLER_NODE_MIN_MAJOR="18"
WRANGLER_INTEGRITY="sha512-qkcwysx96XNDWXl4w/5VjAZjqWatxAq9chMXVeqv/etL9e06ouPaZ+Hwwbe5XYV2GYf/XhZVZ3fHJcTBrq60gQ=="
CLOUDFLARED_VERSION="2026.8.2"
declare -A CLOUDFLARED_SHA256=(
  [amd64]="fcfb02b575a52ca1af2e3267af4e1517bcdeb30ac48c834c69abaed3c0576ad2"
  [arm64]="7747d94570fb390cf47dcb4f9555c193c6355cda9793f0d878d9049e5d6a7790"
  [arm]="19809425f60a6261241dfa66a42b4115bab07c295396a3c4d5d7c247fc4e1412"
)
