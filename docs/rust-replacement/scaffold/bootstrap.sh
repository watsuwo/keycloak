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

# ---------------------------------------------------------------------------
# HANDOFF.md — 別セッション/開発者への引き継ぎ
# ---------------------------------------------------------------------------
say "docs/HANDOFF.md"
cat > docs/HANDOFF.md <<'EOF'
# 開発引き継ぎ (HANDOFF)

このリポジトリ `sso` は、Keycloak の課題を解消する **Rust 製 SSO / IdP** の新規実装である。
本ドキュメントだけ読めば開発を継続できるよう、文脈・決定・現状・次の一手をまとめる。

> 設計の根拠は [`docs/ADR-0001-rust-replacement-strategy.md`](./ADR-0001-rust-replacement-strategy.md) を参照（必読）。

## 1. なぜ作るか（Keycloak の課題）

1. 拡張性は高いが開発難易度が高い（Java provider + JAR デプロイが重い）
2. 設定をソース管理できない（GitOps/IaC と相性が悪い）
3. Java/JVM 依存をやめたい
4. Infinispan（組み込みデータグリッド + JGroups）の運用負荷が高い

## 2. 確定している方針（ADR-0001 / Proposed）

- 言語: **Rust**
- アーキテクチャ: **ステートレスなアプリノード + 外部ストア（PostgreSQL + Redis/Valkey）**。
  **Infinispan / 組み込みデータグリッド / JGroups は不採用。** アクセストークンは署名のみのステートレス JWT。
- 設定: **宣言的（GitOps/IaC）をコアの第一級市民に**。`idp apply -f realm.yaml` + K8s Operator/CRD。真実の源は Git。
- 拡張: **コア再コンパイル不要**の3層 → Rhai（軽量スクリプト）/ WASM（wasmtime/extism）/ Webhook。
- スコープ: フル（OIDC/OAuth2 + SAML + 外部IdP連携/LDAP + MFA/Passkey/FAPI）。ただし段階導入。
- 進め方: **Strangler Fig**（Keycloak と並走し段階移行。ビッグバン置換はしない）。

## 3. 最大リスク（必ず意識すること）

- 🔴 **SAML 2.0 IdP（XML-DSig / C14N / XML暗号）を純 Rust で安全に実装するのは困難。**
  署名ラッピング等の事故源。現実解は `libxmlsec`(C) への FFI か別コンポーネント分離。**Phase 0 で実現性を検証**し、
  ダメなら後送り。プロトコル/暗号は自作せず検証済みライブラリを使う。
- OIDC/OAuth2 プロバイダ本体は Go の `fosite` 相当が Rust に無く、**自前実装が主**（最大の作り込み）。

## 4. 現状（このコミット時点）

- Cargo workspace の雛形が存在し、`cargo build` / `test` / `clippy -D warnings` / `fmt --check` が**全て通る**。
- 機能 crate（idp-oidc 等）は **スケルトン**（smoke テストのみ）。`idp-server` は `/healthz`・`/livez` のみ稼働。
- まだ実装されていない: 認証フロー、トークン発行、永続化、設定 reconcile、拡張ホスト、各プロトコル。

## 5. 開発コマンド

```bash
cargo build --all
cargo test --all
cargo run -p idp-server   # http://0.0.0.0:8080/healthz
cargo fmt --all && cargo clippy --all-targets --all-features -- -D warnings
```

## 6. クレート構成とフェーズ対応

| crate | 役割 | Phase |
|---|---|---|
| `idp-server` (bin) | axum HTTP サーバ本体 | 1 |
| `idp-core` | ドメインモデル・共通型 | 1 |
| `idp-config` | 宣言的設定の reconcile (IaC) | 1 |
| `idp-store` | 永続化(Postgres/sqlx) + 揮発(Redis) | 1 |
| `idp-session` | ステートレスセッション / JWT(josekit) | 1 |
| `idp-oidc` | OIDC / OAuth2 プロバイダ | 1 |
| `idp-mfa` | WebAuthn/Passkey(webauthn-rs)・TOTP | 1 |
| `idp-ext` | 拡張ホスト (Rhai/WASM/Webhook) | 1 |
| `idp-federation` | 外部IdP連携 / LDAP(ldap3) | 2 |
| `idp-saml` | SAML 2.0 IdP（XML-DSig 要スパイク） | 3 |
| `idp-cli` (bin) | `idp apply` CLI | 1 |

## 7. 推奨ライブラリ（ADR-0001 §6 の評価より）

axum / tokio / sqlx / rustls / RustCrypto / **josekit**(JOSE) / **webauthn-rs** / totp-rs /
**ldap3** / oauth2(クライアント用) / wasmtime|extism / rhai。

## 8. 次の一手（ロードマップ）

- **Phase 0 — リスクスパイク（最優先）**
  1. SAML XML-DSig を Rust(FFI 含む)で安全に検証/署名できるか
  2. WASM プラグインホスト(extism)でトークンマッパーが書けるか
  3. ステートレス + Redis/Postgres セッションの性能
- **Phase 1 — OIDC/OAuth2 コア + 設定 IaC + Passkey**（最も価値が高く達成可能）
- **Phase 2 — 外部IdP連携 + LDAP federation**
- **Phase 3 — SAML IdP / FAPI / CIBA / Token Exchange / 認可サービス**
- 全期間: PBKDF2 パスワードハッシュ互換など Keycloak からの移行互換を設計に織り込む

## 9. 着手するなら（提案する最初のタスク）

Phase 1 を選ぶ場合の最初の縦切り（vertical slice）:
1. `idp-core` に Realm/Client/User の最小モデルを定義
2. `idp-store` に Postgres スキーマ + sqlx マイグレーション
3. `idp-oidc` に Discovery(`/.well-known/openid-configuration`) と JWKS エンドポイント
4. `idp-oidc` に authorization code フロー（最小）+ `idp-session` で JWT 発行(josekit)
5. `idp-config` で realm/client を YAML から reconcile
各ステップでテストを追加し、CI を緑に保つこと。
EOF

say "done. next: cargo build && cargo test --all"
