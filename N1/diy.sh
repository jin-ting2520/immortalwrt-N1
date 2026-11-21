#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
WORKSPACE="${GITHUB_WORKSPACE:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
readonly WORKSPACE
TMP_DIR="$(mktemp -d)"
readonly TMP_DIR

# 第三方插件固定 tag 或 commit，避免上游变动导致构建不可复现。
readonly AMLOGIC_REF="26.11.0801-js"
readonly EASYTier_REF="v2.6.4"
readonly NGINX_MANAGER_REF="v1.8.11-1"
readonly ISTORE_COMMIT="a97ace34f2da358a015b094d326bba2697697f2e"

trap 'printf "diy.sh failed at line %s: %s\n" "${BASH_LINENO[0]}" "${BASH_COMMAND}" >&2' ERR
trap 'rm -rf -- "${TMP_DIR}"' EXIT

# 删除上游可能残留的同名插件目录，避免重复定义。
rm -rf -- package/luci-app-amlogic

# 引入第三方插件。24.10 保留上游 Go feed，OpenList 固定为兼容 Go 1.23 的最后版本；
# 25.12 用 OpenListTeam 的 Go 27.x 替换 feed，满足 OpenList 的 go 1.26.4/toolchain 1.27.3。
if [ "${REPO_BRANCH:-openwrt-25.12}" = "openwrt-25.12" ]; then
  rm -rf -- feeds/packages/lang/golang
  git clone --depth=1 --branch 27.x https://github.com/OpenListTeam/packages_lang_golang.git feeds/packages/lang/golang
  OPENLIST_REF="$(
    curl -fsSL https://api.github.com/repos/OpenListTeam/OpenList/releases/latest |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])'
  )"
  case "${OPENLIST_REF}" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) printf '无效的 OpenList 最新版本标签: %s\n' "${OPENLIST_REF}" >&2; exit 1 ;;
  esac
  git ls-remote --exit-code --tags \
    https://github.com/OpenListTeam/OpenList-OpenWRT.git \
    "refs/tags/${OPENLIST_REF}" >/dev/null
else
  # OpenList 4.2.x 要求 Go 1.24+，v4.1.10 是 24.10 原生 Go 1.23 可用的最后版本。
  OPENLIST_REF="v4.1.10"
fi

git clone --depth=1 --branch "${AMLOGIC_REF}" https://github.com/ophub/luci-app-amlogic.git package/luci-app-amlogic
git clone --depth=1 --branch "${EASYTier_REF}" https://github.com/EasyTier/luci-app-easytier.git package/luci-app-easytier
git clone --depth=1 --branch "${NGINX_MANAGER_REF}" https://github.com/hello-yunshu/luci-app-nginx-manager.git package/luci-app-nginx-manager
git clone --depth=1 --branch "${OPENLIST_REF}" https://github.com/OpenListTeam/OpenList-OpenWRT.git package/openlist

# iStore：仓库没有 tag，固定到 commit；25.12 的依赖链无法选中 luci-app-store，
# 只在 24.10 集成，25.12 不复制也不选择。
if [ "${REPO_BRANCH:-}" = "openwrt-24.10" ]; then
  rm -rf -- package/luci-app-store package/luci-lib-taskd package/luci-lib-xterm package/taskd
  git init -q "${TMP_DIR}/istore"
  git -C "${TMP_DIR}/istore" remote add origin https://github.com/istoreos/istore.git
  git -C "${TMP_DIR}/istore" fetch -q --depth=1 origin "${ISTORE_COMMIT}"
  git -C "${TMP_DIR}/istore" checkout -q FETCH_HEAD
  for istore_pkg in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
    cp -a -- "${TMP_DIR}/istore/luci/${istore_pkg}" package/
  done
fi

# 25.12 的 luci-app-acme 和 acme-acmesh-dnsapi 仍依赖已移除的 acme shorthand；
# 直接改成依赖 acme-acmesh，避免空包和 Kconfig 递归依赖。
# cloudflared 固定 golang1.27/host，而 Go feed 已被替换成 golang，需要同步改写。
if [ "${REPO_BRANCH:-}" = "openwrt-25.12" ]; then
  luci_acme_mk="feeds/luci/applications/luci-app-acme/Makefile"
  acme_acmesh_mk="feeds/packages/net/acme-acmesh/Makefile"
  if [ -f "${luci_acme_mk}" ]; then
    sed -i 's/^LUCI_DEPENDS:=+luci-base +acme$/LUCI_DEPENDS:=+luci-base +acme-acmesh/' "${luci_acme_mk}"
  fi
  if [ -f "${acme_acmesh_mk}" ]; then
    sed -i 's/^  DEPENDS:=+acme$/  DEPENDS:=+acme-acmesh/' "${acme_acmesh_mk}"
  fi
  if [ -f feeds/packages/net/cloudflared/Makefile ]; then
    sed -i 's|golang1\.27/host|golang/host|' feeds/packages/net/cloudflared/Makefile
  fi
fi

# 写入插件选择。
cat >> .config <<'EOF'

CONFIG_PACKAGE_luci-app-amlogic=y
CONFIG_PACKAGE_luci-app-ddns-go=y
CONFIG_PACKAGE_luci-app-homeproxy=y
CONFIG_PACKAGE_luci-app-easytier=y
CONFIG_PACKAGE_luci-app-nginx-manager=y
CONFIG_PACKAGE_luci-app-openlist=y
EOF

# 修改默认管理地址。
sed -i 's/192\.168\.1\.1/192.168.123.2/g' package/base-files/files/bin/config_generate

# 按源码版本设置 Amlogic 在线更新标签，避免 24.10/25.12 互相匹配；
# 同时关闭 bootloader 写入，防止在线更新破坏 N1 引导。
if [ -f files/etc/config/amlogic ]; then
  if [ -n "${RELEASE_VERSION:-}" ]; then
    sed -i "s|option amlogic_firmware_tag '.*'|option amlogic_firmware_tag 'OpenWrt_${RELEASE_VERSION}_'|" files/etc/config/amlogic
  fi
  sed -i "s|option amlogic_write_bootloader '.*'|option amlogic_write_bootloader '0'|" files/etc/config/amlogic
fi

# amlogic 的 init 在 START=60 把 CPU governor/频率写入 sysfs；把 cpufreq 调到
# START=61，未配置时它仍是 no-op，保存过设置后则以 cpufreq 为准。
if [ -f package/emortal/cpufreq/files/cpufreq.init ]; then
  sed -i 's/^START=15$/START=61/' package/emortal/cpufreq/files/cpufreq.init
fi

# 修改默认主题：luci 和 luci-light 两个 collection 都要替换，
# 否则 luci-light 仍会把 luci-theme-bootstrap 装进固件。
for collection in feeds/luci/collections/luci/Makefile feeds/luci/collections/luci-light/Makefile; do
  if [ -f "${collection}" ]; then
    sed -i 's/luci-theme-design/luci-theme-argon/g; s/luci-theme-bootstrap/luci-theme-argon/g' "${collection}"
  fi
done

# 安装 Argon 主题资源。
readonly ARGON_DIR="${WORKSPACE}/argon"
readonly ARGON_TARGET="feeds/luci/themes/luci-theme-argon"
mkdir -p -- "${ARGON_TARGET}/htdocs/luci-static/argon/img" \
  "${ARGON_TARGET}/htdocs/luci-static/argon/icon"
cp -f -- "${ARGON_DIR}/background/background.jpg" "${ARGON_TARGET}/htdocs/luci-static/argon/img/bg1.jpg"
cp -f -- "${ARGON_DIR}/img/argon.svg" "${ARGON_TARGET}/htdocs/luci-static/argon/img/argon.svg"
cp -f -- "${ARGON_DIR}/favicon.ico" "${ARGON_TARGET}/htdocs/luci-static/argon/favicon.ico"
for icon in "${ARGON_DIR}"/icon/*.png; do
  cp -f -- "${icon}" "${ARGON_TARGET}/htdocs/luci-static/argon/icon/$(basename -- "${icon}")"
done
