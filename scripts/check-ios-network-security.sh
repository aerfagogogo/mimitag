#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/ios/mimitag/Resources/Info.plist"

plutil -lint "$INFO_PLIST" >/dev/null

# iOS 27 实测中 NSAllowsLocalNetworking 仍会拦截 Tailscale 裸 IP HTTP。
# 系统层需允许 HTTP，真正的安全边界由 EndpointTransportPolicy 在 REST 和 WebSocket 请求前统一执行。
# 用系统 Ruby 解析 plutil JSON，避免 CI 额外安装依赖。
plutil -convert json -o - "$INFO_PLIST" | ruby -rjson -e '
  info = JSON.parse(STDIN.read)
  ats = info.fetch("NSAppTransportSecurity")

  abort "必须启用 NSAllowsArbitraryLoads，否则 iOS 27 会拦截 Tailscale 裸 IP HTTP" unless ats["NSAllowsArbitraryLoads"] == true
  abort "不得同时声明 NSAllowsLocalNetworking；新系统会因此忽略 NSAllowsArbitraryLoads" if ats.key?("NSAllowsLocalNetworking")

  domains = ats.fetch("NSExceptionDomains", {})
  insecure_domains = domains.each_with_object([]) do |(name, settings), result|
    result << name if settings.is_a?(Hash) && settings["NSExceptionAllowsInsecureHTTPLoads"] == true
  end
  unexpected = insecure_domains - ["ts.net"]
  abort "发现未批准的 HTTP ATS 例外：#{unexpected.join(", ")}" unless unexpected.empty?
'

echo "iOS ATS 配置检查通过：系统层允许 Tailscale HTTP，应用层负责拒绝公网 HTTP"
