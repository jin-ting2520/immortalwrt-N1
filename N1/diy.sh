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
readonly OPENCLASH_REF="v0.48.002"
readonly ISTORE_COMMIT="a97ace34f2da358a015b094d326bba2697697f2e"

trap 'printf "diy.sh failed at line %s: %s\n" "${BASH_LINENO[0]}" "${BASH_COMMAND}" >&2' ERR
trap 'rm -rf -- "${TMP_DIR}"' EXIT

# 删除上游可能残留的同名插件目录，避免重复定义。
rm -rf -- package/luci-app-amlogic

# 引入第三方插件。24.10 保留上游 Go feed，OpenList 固定为兼容 Go 1.23 的最后版本；
# 25.12 使用 Go 27.x 并跟随 OpenList 最新 Release。
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

# OpenClash：仓库根目录包含 luci-app-openclash/，只复制这个包。
rm -rf -- package/luci-app-openclash
git clone --depth=1 --branch "${OPENCLASH_REF}" https://github.com/vernesong/OpenClash.git "${TMP_DIR}/openclash"
cp -a -- "${TMP_DIR}/openclash/luci-app-openclash" package/luci-app-openclash

# iStore：仓库没有 tag，固定到 commit；只复制 luci/ 下的四个包。
rm -rf -- package/luci-app-store package/luci-lib-taskd package/luci-lib-xterm package/taskd
git init -q "${TMP_DIR}/istore"
git -C "${TMP_DIR}/istore" remote add origin https://github.com/istoreos/istore.git
git -C "${TMP_DIR}/istore" fetch -q --depth=1 origin "${ISTORE_COMMIT}"
git -C "${TMP_DIR}/istore" checkout -q FETCH_HEAD
for istore_pkg in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
  cp -a -- "${TMP_DIR}/istore/luci/${istore_pkg}" package/
done

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
