#!/usr/bin/env bash
# 交叉编译 apps/ 下全部用户应用 (静态链接), 产物: out/apps/<name>/<name>
# 新加应用: 新建 apps/<name>/{<name>.c,Makefile}, 参照 apps/hello
set -euo pipefail
. "$(dirname "$0")/env.sh"

APPS_DIR="${ROOT_DIR}/apps"
[ -d "${APPS_DIR}" ] || die "缺少 ${APPS_DIR}, 请先创建应用目录"

# shellcheck disable=SC2231
for mk in "${APPS_DIR}"/*/Makefile; do
  [ -e "${mk}" ] || continue
  name="$(basename "$(dirname "${mk}")")"
  aout="${OUT_DIR}/apps/${name}"
  mkdir -p "${aout}"
  log "编译应用: ${name}"
  make -C "$(dirname "${mk}")" OUTPUT="${aout}" CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}"
  bin="${aout}/${name}"
  require_file "${bin}"
  file "${bin}" | grep -q 'ARM' || die "应用 ${name} 编译产物不是 ARM 格式: ${bin}"
done

log "apps 编译完成: ${OUT_DIR}/apps"
