#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVICE_CONFIG_FILE="${1:-${CONFIG_FILE:-}}"
GENERAL_CONFIG_FILE="${2:-${GENERAL_CONFIG_FILE:-configs/General.config}}"
GIT_CLONE_RETRY_COUNT="${GIT_CLONE_RETRY_COUNT:-3}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"

case "$GIT_CLONE_RETRY_COUNT" in
  '' | *[!0-9]* | 0)
    echo "Error: GIT_CLONE_RETRY_COUNT must be a positive integer" >&2
    exit 1
    ;;
esac

resolve_config_file() {
  local config_file="$1"

  if [ -f "$config_file" ]; then
    printf '%s\n' "$config_file"
  elif [ -f "$WORKSPACE/$config_file" ]; then
    printf '%s\n' "$WORKSPACE/$config_file"
  else
    echo "Error: configuration file was not found: $config_file" >&2
    return 1
  fi
}

CONFIG_FILES=()
if [ -n "$DEVICE_CONFIG_FILE" ]; then
  CONFIG_FILES+=("$(resolve_config_file "$DEVICE_CONFIG_FILE")")
elif [ -f .config ]; then
  # Keep direct invocations compatible with an existing OpenWrt .config.
  CONFIG_FILES+=("$PWD/.config")
else
  echo "Error: pass the device config as the first argument or CONFIG_FILE" >&2
  exit 1
fi
CONFIG_FILES+=("$(resolve_config_file "$GENERAL_CONFIG_FILE")")

config_symbol_enabled() {
  local symbol="$1"

  awk -v symbol="$symbol" '
    { sub(/\r$/, "") }
    $0 == symbol "=y" || $0 == symbol "=m" { enabled = 1; next }
    $0 == symbol "=n" || $0 == "# " symbol " is not set" { enabled = 0 }
    END { exit(enabled ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

target_device_package_enabled() {
  local package_name="$1"

  awk -v package_name="$package_name" '
    { sub(/\r$/, "") }
    /^CONFIG_TARGET_DEVICE_PACKAGES_[^=]+="/ {
      packages = $0
      sub(/^[^"]*"/, "", packages)
      sub(/"$/, "", packages)
      count = split(packages, values, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (values[i] == package_name) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

package_enabled() {
  local package_name

  for package_name in "$@"; do
    if config_symbol_enabled "CONFIG_PACKAGE_$package_name" || target_device_package_enabled "$package_name"; then
      return 0
    fi
  done

  return 1
}

clone_with_retry() {
  local target_dir="$1"
  local attempt
  shift

  for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
    rm -rf "$target_dir"
    if git clone "$@" "$target_dir"; then
      return 0
    fi

    if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
      echo "Git clone failed; retrying ($((attempt + 1))/$GIT_CLONE_RETRY_COUNT): ${*: -1}" >&2
      sleep $((attempt * 2))
    fi
  done

  echo "Error: git clone failed after $GIT_CLONE_RETRY_COUNT attempts: ${*: -1}" >&2
  return 1
}

record_git_revision() {
  local repo_url="$1"
  local branch="$2"
  local checkout_dir="$3"
  local commit
  local revision

  commit="$(git -C "$checkout_dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"

  clone_with_retry "$target_dir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    "$repo_url"
  record_git_revision "$repo_url" "$branch" "$target_dir"
}

mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

# 修改默认IP & 固件名称 & 编译署名和时间
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
grep -Fq "$firmware_version_anchor" "$luci_system_js" || { echo "Error: LuCI firmware version anchor was not found in $luci_system_js" >&2; exit 1; }
sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
            _('Firmware Version'),\n \
            E('span', {}, [\n \
                (L.isObject(boardinfo.release)\n \
                ? boardinfo.release.description + ' / '\n \
                : '') + (luciversion || '') + ' / ',\n \
            E('a', {\n \
                href: 'https://github.com/zk6685/zk-laipengwrt/releases',\n \
                target: '_blank',\n \
                rel: 'noopener noreferrer'\n \
                }, [ 'Built by zk6685 $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
            ]),#" "$luci_system_js"

# 调整NN6000 v1/v2内核分区大小为12M（原为6144k/6M，改为12288k/12M）
ipq60xx_mk="target/linux/qualcommax/image/ipq60xx.mk"
if [ -f "$ipq60xx_mk" ]; then
  sed -i '/^define Device\/link_nn6000-v1/,/^endef/ s/^\([[:space:]]*KERNEL_SIZE := \)[0-9]*k/\112288k/' "$ipq60xx_mk"
  sed -i '/^define Device\/link_nn6000-v2/,/^endef/ s/^\([[:space:]]*KERNEL_SIZE := \)[0-9]*k/\112288k/' "$ipq60xx_mk"
  if grep -q 'KERNEL_SIZE := 12288k' "$ipq60xx_mk"; then
    echo "NN6000 kernel partition size adjusted to 12M"
  else
    echo "Warning: NN6000 KERNEL_SIZE was not adjusted to 12M in $ipq60xx_mk" >&2
  fi
else
  echo "Warning: $ipq60xx_mk not found, skip kernel size adjustment" >&2
fi

# 双保险：直接 patch qualcommax 内核 config，开 BTF/eBPF/XCAL 支持（luci-app-daed 运行前提）
# 防止 OpenWrt defconfig 重置（之前 #1 就栽在 BPF_TOOLCHAIN_HOST 被重置）
set_kconfig() {
  local f="$1" sym="$2" val="$3"
  [ -f "$f" ] || return 0
  sed -i "/^#[[:space:]]*CONFIG_${sym}[[:space:]]*is not set/d" "$f"
  sed -i "/^CONFIG_${sym}=/d" "$f"
  echo "CONFIG_${sym}=${val}" >> "$f"
}
for kcfg in target/linux/qualcommax/config-6.12 target/linux/qualcommax/config-6.6; do
  if [ -f "$kcfg" ]; then
    set_kconfig "$kcfg" DEBUG_INFO y
    set_kconfig "$kcfg" DEBUG_INFO_REDUCED n
    set_kconfig "$kcfg" DEBUG_INFO_BTF y
    set_kconfig "$kcfg" CGROUPS y
    set_kconfig "$kcfg" CGROUP_BPF y
    set_kconfig "$kcfg" BPF_EVENTS y
    set_kconfig "$kcfg" XDP_SOCKETS y
    echo "BTF/eBPF kernel config patched in $kcfg"
  fi
done

# 删除 miniupnpd 2.3.11 失效 patch（上游 feeds 更新后 patch 与源码对不上，Run #18 在此失败）
miniupnpd_bad_patch="feeds/packages/net/miniupnpd/patches/020-descr-filter-fix.patch"
if [ -f "$miniupnpd_bad_patch" ]; then
  rm -f "$miniupnpd_bad_patch"
  echo "Removed stale miniupnpd patch: $miniupnpd_bad_patch"
fi

# 调整NSS驱动q6_region内存区域预留大小（ipq6018.dtsi默认预留85MB，ipq6018-512m.dtsi默认预留55MB，带WiFi必须至少预留54MB，以下分别是改成预留16MB、32MB、64MB和96MB）
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x02000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x06000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi

# 调节IPQ60XX的1.5GHz频率电压(从0.9375V提高到0.95V，过低可能导致不稳定，过高可能增加功耗和发热，具体数值需要根据实际情况调整)
# sed -i 's/opp-microvolt = <937500>;/opp-microvolt = <950000>;/' target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch

# Git稀疏克隆，只克隆指定目录到本地
git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local repodir
  local sparse_path
  shift 2

  repodir="$(basename "${repourl%.git}")"
  clone_with_retry "$repodir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl"
  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )
  record_git_revision "$repourl" "$branch" "$repodir"

  for sparse_path in "$@"; do
    rm -rf "package/$(basename "$sparse_path")"
    mv "$repodir/$sparse_path" package/
  done
  rm -rf "$repodir"
}

# Aria2 & nginx & Go & DDNS & frp & UPnP & Wol
rm -rf feeds/packages/lang/golang
git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv package/golang feeds/packages/lang/golang

if package_enabled luci-app-aria2 aria2; then
  rm -rf feeds/packages/net/aria2
  git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2
  mv package/aria2 feeds/packages/net/aria2
fi
if package_enabled ariang; then
  rm -rf feeds/packages/net/ariang
  git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang
  mv package/ariang feeds/packages/net/ariang
fi

if package_enabled nginx nginx-full nginx-ssl luci-app-nginx; then
  rm -rf feeds/packages/net/nginx
  git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx
  mv package/nginx feeds/packages/net/nginx
fi

if package_enabled luci-app-ddns ddns-scripts ddns-scripts-cloudflare; then
  rm -rf feeds/packages/net/ddns-scripts
  git_sparse_clone master https://github.com/laipeng668/packages net/ddns-scripts
  mv package/ddns-scripts feeds/packages/net/ddns-scripts
fi
if package_enabled luci-app-ddns; then
  rm -rf feeds/luci/applications/luci-app-ddns
  git_sparse_clone master https://github.com/laipeng668/luci applications/luci-app-ddns
  mv package/luci-app-ddns feeds/luci/applications/luci-app-ddns
fi

if package_enabled frp frpc frps luci-app-frpc luci-app-frps; then
  rm -rf \
    feeds/packages/net/frp
  git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp
  mv package/frp feeds/packages/net/frp
fi

frp_luci_paths=()
if package_enabled luci-app-frpc; then
  rm -rf feeds/luci/applications/luci-app-frpc
  frp_luci_paths+=(applications/luci-app-frpc)
fi
if package_enabled luci-app-frps; then
  rm -rf feeds/luci/applications/luci-app-frps
  frp_luci_paths+=(applications/luci-app-frps)
fi
if [ "${#frp_luci_paths[@]}" -gt 0 ]; then
  git_sparse_clone frp https://github.com/laipeng668/luci "${frp_luci_paths[@]}"
  for frp_luci_path in "${frp_luci_paths[@]}"; do
    mv "package/$(basename "$frp_luci_path")" "feeds/luci/$frp_luci_path"
    sed -i '/^LUCI_EXTRA_DEPENDS:=/d' "feeds/luci/$frp_luci_path/Makefile"
  done
fi

if package_enabled luci-app-upnp miniupnpd; then
  rm -rf feeds/packages/net/miniupnpd
  git_sparse_clone master https://github.com/immortalwrt/packages net/miniupnpd
  mv package/miniupnpd feeds/packages/net/miniupnpd
fi
if package_enabled luci-app-upnp; then
  rm -rf feeds/luci/applications/luci-app-upnp
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-upnp
  mv package/luci-app-upnp feeds/luci/applications/luci-app-upnp
fi

if package_enabled luci-app-wol; then
  rm -rf feeds/luci/applications/luci-app-wol
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-wol
  mv package/luci-app-wol feeds/luci/applications/luci-app-wol
fi

# Themes and standalone applications. A config application pulls in its theme as a dependency.
if package_enabled luci-theme-argon luci-app-argon-config; then
  rm -rf feeds/luci/themes/luci-theme-argon
  clone_repository https://github.com/jerrykuku/luci-theme-argon master feeds/luci/themes/luci-theme-argon
fi
if package_enabled luci-app-argon-config; then
  rm -rf feeds/luci/applications/luci-app-argon-config
  clone_repository https://github.com/jerrykuku/luci-app-argon-config master feeds/luci/applications/luci-app-argon-config
fi

if package_enabled luci-theme-aurora luci-app-aurora-config; then
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

if package_enabled luci-app-openlist2 openlist2; then
  clone_repository https://github.com/laipeng668/luci-app-openlist2 main package/openlist2
fi

if package_enabled luci-app-lucky lucky; then
  clone_repository https://github.com/gdy666/luci-app-lucky main package/luci-app-lucky
fi

if package_enabled luci-app-wechatpush; then
  rm -rf feeds/luci/applications/luci-app-wechatpush
  clone_repository https://github.com/tty228/luci-app-wechatpush master package/luci-app-wechatpush
fi

if package_enabled luci-app-oaf open-app-filter; then
  rm -rf feeds/luci/applications/luci-app-appfilter feeds/packages/net/open-app-filter
  clone_repository https://github.com/destan19/OpenAppFilter.git master package/OpenAppFilter
fi

if package_enabled luci-app-gecoosac gecoosac; then
  clone_repository https://github.com/laipeng668/luci-app-gecoosac main package/luci-app-gecoosac
fi

if package_enabled luci-app-athena-led luci-i18n-athena-led-zh-cn; then
  clone_repository https://github.com/NONGFAH/luci-app-athena-led main package/luci-app-athena-led
  chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led
fi

### PassWall & OpenClash ###

if package_enabled luci-app-passwall luci-app-passwall2; then
  # 移除 OpenWrt Feeds 自带的核心库
  rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall-packages main package/passwall-packages
fi

if package_enabled luci-app-passwall; then
  rm -rf feeds/luci/applications/luci-app-passwall
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall main package/luci-app-passwall
fi

if package_enabled luci-app-passwall2; then
  rm -rf feeds/luci/applications/luci-app-passwall2
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall2 main package/luci-app-passwall2
fi

if package_enabled luci-app-openclash; then
  rm -rf feeds/luci/applications/luci-app-openclash
  clone_repository https://github.com/vernesong/OpenClash master package/luci-app-openclash
fi

# ---- zk6685 定制插件源（优先 laipeng668，其余为对应上游）----
if package_enabled luci-app-mosdns mosdns geo2txt; then
  rm -rf feeds/luci/applications/luci-app-mosdns feeds/packages/net/mosdns feeds/packages/net/geo2txt
  clone_repository https://github.com/sbwml/luci-app-mosdns v5 package/mosdns
  mv package/mosdns/luci-app-mosdns feeds/luci/applications/luci-app-mosdns
  mv package/mosdns/mosdns feeds/packages/net/mosdns
  mv package/mosdns/geo2txt feeds/packages/net/geo2txt
  rm -rf package/mosdns
fi

if package_enabled luci-app-filebrowser filebrowser; then
  rm -rf feeds/packages/net/filebrowser feeds/luci/applications/luci-app-filebrowser
  git_sparse_clone master https://github.com/kenzok8/openwrt-packages filebrowser
  mv package/filebrowser feeds/packages/net/filebrowser
  git_sparse_clone master https://github.com/kenzok8/openwrt-packages luci-app-filebrowser
  mv package/luci-app-filebrowser feeds/luci/applications/luci-app-filebrowser
  # filebrowser 主包提供 config/init，删除 luci-app 自带 root/etc 避免 apk 安装冲突
  rm -rf feeds/luci/applications/luci-app-filebrowser/root/etc
fi

if package_enabled luci-app-mosquitto mosquitto mosquitto-ssl mosquitto-client-ssl; then
  rm -rf feeds/packages/net/mosquitto feeds/packages/lang/lua/lua-mosquitto
  git_sparse_clone master https://github.com/laipeng668/packages net/mosquitto
  mv package/mosquitto feeds/packages/net/mosquitto
fi

if package_enabled docker dockerd luci-app-dockerman; then
  rm -rf feeds/packages/utils/docker feeds/packages/utils/dockerd feeds/packages/utils/docker-compose
  git_sparse_clone master https://github.com/laipeng668/packages utils/docker
  mv package/docker feeds/packages/utils/docker
  git_sparse_clone master https://github.com/laipeng668/packages utils/dockerd
  mv package/dockerd feeds/packages/utils/dockerd
  git_sparse_clone master https://github.com/laipeng668/packages utils/docker-compose
  mv package/docker-compose feeds/packages/utils/docker-compose
fi
if package_enabled luci-app-dockerman; then
  rm -rf feeds/luci/applications/luci-app-dockerman
  git_sparse_clone master https://github.com/laipeng668/luci applications/luci-app-dockerman
  mv package/luci-app-dockerman feeds/luci/applications/luci-app-dockerman
fi

if package_enabled luci-app-clouddrive2 clouddrive2; then
  rm -rf feeds/packages/net/clouddrive2 feeds/luci/applications/luci-app-clouddrive2
  clone_repository https://github.com/xuanranran/openwrt-clouddrive2 master package/clouddrive2-src
  mv package/clouddrive2-src/clouddrive2 feeds/packages/net/clouddrive2
  mv package/clouddrive2-src/luci-app-clouddrive2 feeds/luci/applications/luci-app-clouddrive2
  rm -rf package/clouddrive2-src
fi

if package_enabled luci-app-istorex luci-app-store luci-lib-taskd luci-app-quickstart; then
  rm -rf feeds/luci/applications/luci-app-istorex feeds/luci/applications/luci-app-store \
        feeds/luci/applications/luci-app-quickstart feeds/luci/libs/luci-lib-taskd \
        feeds/luci/luci-nginxer feeds/luci/luci-lib-iform feeds/luci/luci-lib-linkeaseauth \
        feeds/luci/luci-lib-linkeasefile
  git_sparse_clone main https://github.com/linkease/nas-packages-luci luci/luci-app-istorex
  mv package/luci-app-istorex feeds/luci/applications/luci-app-istorex
  git_sparse_clone main https://github.com/linkease/nas-packages-luci luci/luci-app-quickstart
  mv package/luci-app-quickstart feeds/luci/applications/luci-app-quickstart
  git_sparse_clone main https://github.com/linkease/nas-packages-luci luci/luci-nginxer
  mv package/luci-nginxer feeds/luci/luci-nginxer
  git_sparse_clone main https://github.com/linkease/nas-packages-luci luci/luci-lib-iform
  mv package/luci-lib-iform feeds/luci/libs/luci-lib-iform
  git_sparse_clone main https://github.com/linkease/nas-packages-luci luci/luci-lib-linkeaseauth
  mv package/luci-lib-linkeaseauth feeds/luci/libs/luci-lib-linkeaseauth
  git_sparse_clone main https://github.com/linkease/nas-packages-luci luci/luci-lib-linkeasefile
  mv package/luci-lib-linkeasefile feeds/luci/libs/luci-lib-linkeasefile
fi
if package_enabled luci-app-store; then
  rm -rf feeds/luci/applications/luci-app-store feeds/luci/libs/luci-lib-taskd feeds/luci/luci-lib-xterm
  clone_repository https://github.com/linkease/istore main package/istore-store
  mv package/istore-store/luci/luci-app-store feeds/luci/applications/luci-app-store
  mv package/istore-store/luci/luci-lib-taskd feeds/luci/libs/luci-lib-taskd
  mv package/istore-store/luci/luci-lib-xterm feeds/luci/luci-lib-xterm
  mv package/istore-store/luci/taskd feeds/luci/taskd
  rm -rf package/istore-store
fi

# 清理 PassWall 的 chnlist 规则文件
# echo "baidu.com"  > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist

./scripts/feeds update -i -a
./scripts/feeds install -a
