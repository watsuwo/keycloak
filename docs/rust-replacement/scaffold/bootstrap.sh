#!/usr/bin/env bash
#
# bootstrap.sh — Rust 製 SSO/IdP プロジェクトの雛形を生成する。
#
# 使い方:
#   1. 空の GitHub リポジトリ (例: watsuwo/sso) を clone
#   2. その中で本スクリプトを実行:   bash bootstrap.sh
#   3. git add -A && git commit && git push
#
# 既存ファイルは上書きしないよう、主要ファイルは存在チェックしてから生成する。
set -euo pipefail

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

mkdir -p crates docs .github/workflows

# ---------------------------------------------------------------------------
# workspace Cargo.toml
# ---------------------------------------------------------------------------
say "workspace Cargo.toml"
cat > Cargo.toml <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*"]

[workspace.package]
version = "0.0.0"
edition = "2021"
rust-version = "1.85"
license = "Apache-2.0"
repository = "https://github.com/watsuwo/sso"

# 共有依存。各 crate は `dep = { workspace = true }` で参照する。
[workspace.dependencies]
# 非同期ランタイム / HTTP
tokio = { version = "1", features = ["rt-multi-thread", "macros", "signal"] }
axum = "0.8"
tower = "0.5"
tower-http = { version = "0.6", features = ["trace"] }
# ログ / 設定 / エラー
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
anyhow = "1"
thiserror = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
serde_yaml = "0.9"
# 内部 crate
idp-core = { path = "crates/idp-core" }
idp-config = { path = "crates/idp-config" }
idp-store = { path = "crates/idp-store" }
idp-session = { path = "crates/idp-session" }
idp-oidc = { path = "crates/idp-oidc" }
idp-saml = { path = "crates/idp-saml" }
idp-federation = { path = "crates/idp-federation" }
idp-mfa = { path = "crates/idp-mfa" }
idp-ext = { path = "crates/idp-ext" }

[profile.release]
lto = "thin"
EOF

# ---------------------------------------------------------------------------
# ライブラリ crate の雛形を量産するヘルパ
# ---------------------------------------------------------------------------
make_lib_crate() {
  local name="$1"; shift
  local desc="$1"; shift
  mkdir -p "crates/${name}/src"
  cat > "crates/${name}/Cargo.toml" <<EOF
[package]
name = "${name}"
description = "${desc}"
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true
EOF
  cat > "crates/${name}/src/lib.rs" <<EOF
//! ${desc}
//!
//! 現状はスケルトン。ADR-0001 のフェーズ計画に沿って実装を追加する。

/// crate が正しくリンクされているかの最小スモークテスト用。
pub fn crate_name() -> &'static str {
    "${name}"
}

#[cfg(test)]
mod tests {
    #[test]
    fn smoke() {
        assert_eq!(super::crate_name(), "${name}");
    }
}
EOF
}

say "library crates"
make_lib_crate idp-core       "ドメインモデル・共通型 (Realm/Client/User/Token など)"
make_lib_crate idp-config     "宣言的設定(IaC)の読み込みと reconcile (GitOps)"
make_lib_crate idp-store      "永続化 (PostgreSQL/sqlx) と揮発ストア (Redis/Valkey)。Infinispan 非依存"
make_lib_crate idp-session    "ステートレスセッションと JWT 発行/失効"
make_lib_crate idp-oidc       "OIDC / OAuth 2.0 プロバイダ (Phase1 中心)"
make_lib_crate idp-saml       "SAML 2.0 IdP (Phase3 / XML-DSig は要スパイク)"
make_lib_crate idp-federation "外部 IdP 連携 (OIDC/SAML as client) と LDAP federation (Phase2)"
make_lib_crate idp-mfa        "WebAuthn/Passkey・TOTP などの多要素認証"
make_lib_crate idp-ext        "拡張ホスト (Rhai スクリプト / WASM / Webhook)"

# ---------------------------------------------------------------------------
# idp-server (実行バイナリ・axum)
# ---------------------------------------------------------------------------
say "crates/idp-server (axum binary)"
mkdir -p crates/idp-server/src
cat > crates/idp-server/Cargo.toml <<'EOF'
[package]
name = "idp-server"
description = "HTTP サーバ本体 (axum)。各機能 crate を束ねるエントリポイント"
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true

[[bin]]
name = "idp-server"
path = "src/main.rs"

[dependencies]
tokio = { workspace = true }
axum = { workspace = true }
tower-http = { workspace = true }
tracing = { workspace = true }
tracing-subscriber = { workspace = true }
anyhow = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
idp-core = { workspace = true }
EOF
cat > crates/idp-server/src/main.rs <<'EOF'
//! HTTP サーバのエントリポイント。
//!
//! 現状は `/healthz` と `/livez` のみ。ADR-0001 Phase1 で OIDC/OAuth ルートを追加する。

use axum::{routing::get, Json, Router};
use serde_json::json;
use tower_http::trace::TraceLayer;

fn app() -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/livez", get(|| async { "ok" }))
        .layer(TraceLayer::new_for_http())
}

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok", "service": "sso", "version": env!("CARGO_PKG_VERSION") }))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let addr = std::env::var("IDP_LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!(%addr, "sso listening");
    axum::serve(listener, app()).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt; // for `oneshot`

    #[tokio::test]
    async fn healthz_ok() {
        let res = app()
            .oneshot(
                Request::builder()
                    .uri("/healthz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
    }
}
EOF
# idp-server のテストは tower の ServiceExt を使うので dev-dependency を足す
cat >> crates/idp-server/Cargo.toml <<'EOF'

[dev-dependencies]
tower = { workspace = true }
EOF

# ---------------------------------------------------------------------------
# idp-cli (実行バイナリ・apply CLI の入口)
# ---------------------------------------------------------------------------
say "crates/idp-cli (apply CLI)"
mkdir -p crates/idp-cli/src
cat > crates/idp-cli/Cargo.toml <<'EOF'
[package]
name = "idp-cli"
description = "宣言的設定を適用する CLI (idp apply ...)。GitOps のクライアント側"
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true
repository.workspace = true

[[bin]]
name = "idp"
path = "src/main.rs"

[dependencies]
anyhow = { workspace = true }
idp-config = { workspace = true }
EOF
cat > crates/idp-cli/src/main.rs <<'EOF'
//! `idp` CLI のエントリポイント (Phase1)。
//!
//! 目標: `idp apply -f realm.yaml` で宣言的設定を reconcile する。

fn main() -> anyhow::Result<()> {
    println!("idp CLI (skeleton) — see ADR-0001 for the roadmap");
    Ok(())
}
EOF

# ---------------------------------------------------------------------------
# 周辺ファイル
# ---------------------------------------------------------------------------
say "toolchain / gitignore / CI / README / LICENSE"

cat > rust-toolchain.toml <<'EOF'
[toolchain]
channel = "stable"
components = ["rustfmt", "clippy"]
EOF

if [ ! -f .gitignore ]; then
cat > .gitignore <<'EOF'
/target
**/*.rs.bk
.env
*.log
EOF
fi

cat > .github/workflows/ci.yml <<'EOF'
name: CI
on:
  push:
    branches: [ main ]
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@v2
      - name: fmt
        run: cargo fmt --all -- --check
      - name: clippy
        run: cargo clippy --all-targets --all-features -- -D warnings
      - name: test
        run: cargo test --all
EOF

if [ ! -f README.md ] || [ "$(wc -l < README.md)" -lt 5 ]; then
cat > README.md <<'EOF'
# sso

Keycloak の課題（拡張開発の難しさ / 設定をソース管理できない / Java 依存 /
Infinispan 運用負荷）を解消する、**Rust 製の SSO / IdP** プロジェクト。

設計の意思決定は [`docs/ADR-0001-rust-replacement-strategy.md`](docs/ADR-0001-rust-replacement-strategy.md) を参照。

## 設計の柱

- **ステートレス + 外部ストア (PostgreSQL + Redis/Valkey)** — Infinispan / 組み込みデータグリッド非依存
- **設定は宣言的 (GitOps/IaC)** — `idp apply -f realm.yaml` + K8s Operator/CRD
- **拡張はコア再コンパイル不要** — Rhai / WASM / Webhook の3層
- **段階導入 (Strangler Fig)** — OIDC/OAuth → 連携/LDAP → SAML/FAPI

## 開発

```bash
cargo build            # 全 crate をビルド
cargo test --all       # テスト
cargo run -p idp-server  # http://0.0.0.0:8080/healthz
```

## ワークスペース構成

| crate | 役割 | フェーズ |
|---|---|---|
| `idp-server` | axum HTTP サーバ本体 | Phase1 |
| `idp-core` | ドメインモデル・共通型 | Phase1 |
| `idp-config` | 宣言的設定の reconcile (IaC) | Phase1 |
| `idp-store` | 永続化(Postgres) + 揮発(Redis) | Phase1 |
| `idp-session` | ステートレスセッション / JWT | Phase1 |
| `idp-oidc` | OIDC / OAuth2 プロバイダ | Phase1 |
| `idp-mfa` | WebAuthn/Passkey・TOTP | Phase1 |
| `idp-ext` | 拡張ホスト (Rhai/WASM/Webhook) | Phase1 |
| `idp-federation` | 外部IdP連携 / LDAP | Phase2 |
| `idp-saml` | SAML 2.0 IdP (XML-DSig 要スパイク) | Phase3 |
| `idp-cli` | `idp apply` CLI | Phase1 |
EOF
fi

if [ ! -f LICENSE ]; then
cat > LICENSE <<'EOF'
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   (Apache-2.0 全文に差し替えてください: https://www.apache.org/licenses/LICENSE-2.0.txt)
EOF
fi

say "done. next: cargo build && cargo test --all"
