#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

mkdir -p .tools .vendor/dws .vendor/lark-cli

verify_sha256() {
    local expected="$1" file_path="$2"
    [[ -f "$file_path" && "$(shasum -a 256 "$file_path" | cut -d ' ' -f 1)" == "$expected" ]]
}

download() {
    local url="$1" file_path="$2"
    curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        --retry-delay 2 --connect-timeout 20 "$url" -o "$file_path.partial"
    mv "$file_path.partial" "$file_path"
}

dws_binary_sha='41eef2e626b4fe95104ad6a638536b45b51052b9754696904c6a5e159deb5ad4'
dws_archive_sha='c01c28dc13948a70fca905207073dc8dbd22f7ba7fc90e68b3316eb9a9c98e88'
if ! verify_sha256 "$dws_binary_sha" .vendor/dws/dws || [[ ! -f .vendor/dws/LICENSE ]]; then
    if ! verify_sha256 "$dws_archive_sha" .tools/dws-darwin-arm64.tar.gz; then
        download 'https://registry.npmjs.org/dingtalk-workspace-cli/-/dingtalk-workspace-cli-1.0.57.tgz' \
            .tools/dingtalk-workspace-cli-1.0.57.tgz
        tar -xOzf .tools/dingtalk-workspace-cli-1.0.57.tgz \
            package/assets/dws-darwin-arm64.tar.gz > .tools/dws-darwin-arm64.tar.gz
    fi
    verify_sha256 "$dws_archive_sha" .tools/dws-darwin-arm64.tar.gz
    tar -xOzf .tools/dws-darwin-arm64.tar.gz ./dws > .vendor/dws/dws.partial
    tar -xOzf .tools/dws-darwin-arm64.tar.gz ./LICENSE > .vendor/dws/LICENSE
    verify_sha256 "$dws_binary_sha" .vendor/dws/dws.partial
    mv .vendor/dws/dws.partial .vendor/dws/dws
    chmod +x .vendor/dws/dws
fi

lark_binary_sha='558a4b3db4beb63ab71f2d2dbc42506846535bc1276f707764ff94809e8441a0'
lark_archive_sha='ee4a3209bbf8b74ea5c00a07d0da89b79f5e7f6abfd518a8b2d78a7a4f7e3f40'
if ! verify_sha256 "$lark_binary_sha" .vendor/lark-cli/lark-cli || [[ ! -f .vendor/lark-cli/LICENSE ]]; then
    if ! verify_sha256 "$lark_archive_sha" .tools/lark-cli-1.0.98-darwin-arm64.tar.gz; then
        download 'https://github.com/larksuite/cli/releases/download/v1.0.98/lark-cli-1.0.98-darwin-arm64.tar.gz' \
            .tools/lark-cli-1.0.98-darwin-arm64.tar.gz
    fi
    verify_sha256 "$lark_archive_sha" .tools/lark-cli-1.0.98-darwin-arm64.tar.gz
    tar -xOzf .tools/lark-cli-1.0.98-darwin-arm64.tar.gz lark-cli > .vendor/lark-cli/lark-cli.partial
    tar -xOzf .tools/lark-cli-1.0.98-darwin-arm64.tar.gz LICENSE > .vendor/lark-cli/LICENSE
    verify_sha256 "$lark_binary_sha" .vendor/lark-cli/lark-cli.partial
    mv .vendor/lark-cli/lark-cli.partial .vendor/lark-cli/lark-cli
    chmod +x .vendor/lark-cli/lark-cli
fi

print '固定版本账号组件已校验。'
