# ADR-0001: Keycloak 後継 IdP を Rust で自作する方針

- ステータス: Proposed（提案 / 叩き台）
- 日付: 2026-05-29
- 決定者: （要記入）
- 関連: 本ディレクトリ配下の後続 ADR

> この文書は「Keycloak の課題を解消した後継 IdP を別言語で自作する」検討の意思決定記録である。
> 確定事項ではなく、チームで叩いて更新していく前提の叩き台。

---

## 1. 背景と課題

現行の Keycloak（Java / Quarkus）に対し、以下の課題が認識されている。

1. **拡張性は高いが開発難易度が高い**: SPI に対して Java で provider を実装し、JAR をビルド・デプロイする必要があり、学習コスト・反復コストが高い。
2. **設定をソース管理できない**: Realm / Client / 認証フロー等の設定が DB に保持され、管理コンソール経由で変更される。GitOps / IaC との相性が悪い（realm export JSON や keycloak-config-cli は後付けで限界がある）。
3. **Java で書かれている**: チームの主要スタックに合わせたい。JVM 運用を避けたい。
4. **Infinispan を使いたくない**: 組み込みデータグリッド + JGroups によるクラスタ運用が複雑で、運用負荷・障害時の調停が辛い。

## 2. 決定（方針サマリ）

- **言語: Rust** で後継 IdP を自作する。
- **アーキテクチャ: ステートレスなアプリノード + 外部ストア**（PostgreSQL + Redis/Valkey）。**Infinispan / 組み込みデータグリッド / JGroups は採用しない。**
- **設定は宣言的リソースとしてコアの第一級市民**にし、GitOps / IaC を前提にする（CLI `apply` + Kubernetes Operator/CRD）。
- **拡張はコア再コンパイル不要**な3層（Rhai スクリプト / WASM プラグイン / Webhook）で提供する。
- **スコープはフル**（OIDC/OAuth2 + SAML + 外部IdP連携/LDAP + MFA/Passkey/FAPI）だが、**段階導入（Strangler Fig）** で価値の出る順に実装する。
- **SAML（XML-DSig）は本プロジェクト最大の技術リスク**として個別に扱う。

## 3. スコープ

### 対象（フルスコープを目標）
- OIDC / OAuth 2.0(2.1) プロバイダ（中心）
- SAML 2.0 IdP（必須）
- Identity Brokering（外部 OIDC/SAML IdP 連携）、User Federation（LDAP 等）
- 高度な機能: WebAuthn/Passkey、MFA(TOTP)、FAPI、CIBA、Token Exchange など

### 当面の非対象 / 後送り（要再評価）
- WS-Federation 等のレガシープロトコル
- UMA 2.0 認可サービスの全機能（Phase 後半）
- マルチテナントの高度要件（別 ADR で検討）

## 4. アーキテクチャ概要

```
         ┌────────────────────────────────────────┐
         │  Load Balancer / Ingress               │
         └───────────────┬────────────────────────┘
                         │   (アプリノードは完全ステートレス・水平スケール)
        ┌────────────┬───┴────────┬────────────┐
        │ idp-node   │ idp-node   │ idp-node   │  ← Rust / axum + tokio
        └─────┬──────┴─────┬──────┴─────┬──────┘
              │            │            │
    ┌─────────┴──┐  ┌──────┴───────┐  ┌─┴───────────────┐
    │ PostgreSQL │  │ Redis/Valkey │  │ External secrets│
    │ 永続状態    │  │ 揮発状態/Hot  │  │ (Vault/K8s)     │
    │ (sqlx)     │  │ session・失効 │  └─────────────────┘
    └────────────┘  └──────────────┘
```

**原則: アプリノードはローカル状態を持たない。** スケールは LB の後ろにノードを足すだけ。ノード間直接通信（JGroups 相当）を排除し、運用を単純化する。

## 5. 課題への設計回答

### 5.1 Infinispan の排除（課題4）

Keycloak が Infinispan に負わせている責務を、外部ストア + ステートレスへ分解する。

| Infinispan の役割 | 置き換え | 補足 |
|---|---|---|
| ユーザーセッション | Redis/Valkey（揮発・TTL）or Postgres | SSO/refresh セッションの実体 |
| アクセストークン | **ステートレス JWT（署名のみ）** | セッション参照を不要化 |
| 認証中の一時状態(auth session) | Redis（短命 TTL） | フロー進行中の状態 |
| Realm/User キャッシュ | in-process キャッシュ(`moka`) + pub/sub 無効化 | 分散グリッド不要。Redis pub/sub で invalidation 配信 |
| ログイン失敗/レート制限 | Redis（atomic counter） | brute-force 防御 |
| 失効リスト(revocation) | Redis | JWT 失効の参照先 |
| クラスタ同期/JGroups | **不要**（共有ストアに集約） | 運用が大幅に簡素化 |

> 補足: Zitadel 流のイベントソーシング（Postgres にイベントを積む）は監査・状態復元に強いが、初手では複雑。別 ADR で Phase 後半の選択肢として検討する。

### 5.2 設定の GitOps / IaC 化（課題2）

**設定を宣言的リソースとしてコアに組み込む（後付けしない）。**

- 対象: Realm / Client / Scope / Mapper / 認証フロー / 外部IdP接続 / LDAP連携 を YAML（または HCL）で定義。
- 反映: ① CLI `apply`（CI から実行） + ② Kubernetes Operator + CRD。
- ドリフト検知: 宣言（Git）と実体（DB）の差分を検出・是正。
- シークレット: インライン禁止。外部参照（Vault / K8s Secret）。
- 思想: **真実の源は Git。DB は reconcile された実体のキャッシュ**と捉える。

### 5.3 拡張モデル（課題1・3）

Rust は動的プラグインに不向きなため、**コア再コンパイル不要の3層**を使い分ける。

1. **Rhai（Rust 製スクリプト）**: トークンマッパー、簡単な条件分岐などの軽量ロジック。最も手軽。
2. **WASM プラグイン（`wasmtime` / `extism`）**: サンドボックス・言語自由（Go/TS/Rust）。カスタム認証ステップ、ポリシー評価向け。
3. **Webhook / 外部サービス（Ory 流）**: 重い業務連携・外部システム呼び出し。言語完全非依存。

→ 「JAR をビルドして再デプロイ」は廃止。拡張は設定でフック点にスクリプト/WASM/Webhook を差し込む形にする。

## 6. Rust エコシステムの現実評価

| 機能 | Rust の状況 | 評価 |
|---|---|---|
| Web フレームワーク | `axum` + `tokio` | ✅ 成熟 |
| 永続化 | `sqlx` / `sea-orm`（Postgres） | ✅ 成熟 |
| 暗号 | `RustCrypto` / `ring` / `rustls` | ✅ 成熟 |
| JWT/JOSE | `josekit`（JWS/JWE/JWK）/ `jsonwebtoken` | ✅ 実用十分 |
| WebAuthn/Passkey | `webauthn-rs` | ✅ Rust の強み |
| TOTP/MFA | `totp-rs` 等 | ✅ 問題なし |
| LDAP 連携 | `ldap3` | ✅ 実用十分 |
| OAuth2 クライアント(連携用) | `oauth2` | ✅ 良好 |
| **OIDC/OAuth2 プロバイダ本体** | Go の `fosite` 相当が無い。`oxide-auth` は限定的 | ⚠️ 自前実装が主（最大の作り込み） |
| **SAML 2.0 IdP** | `samael` はあるが XML署名(XML-DSig)/C14N/XML暗号が鬼門。純Rust 本番品質はほぼ無く `libxmlsec`(C) への FFI が現実解 | 🔴 **最大の技術リスク** |

## 7. リスクと対応

| リスク | 影響 | 対応 |
|---|---|---|
| **SAML(XML-DSig) を純 Rust で安全に実装困難** | 署名ラッピング等のセキュリティ事故、Phase3 が破綻 | Phase0 で実現性検証。SAML だけ libxmlsec への FFI で慎重実装、または別コンポーネントに責務分離。最悪 SAML を後送り |
| プロトコル/暗号の自作によるセキュリティ欠陥 | 致命的脆弱性 | プロトコル・暗号は自作せず検証済みライブラリを使用。外部監査・OIDC/FAPI 適合性テスト(conformance)を CI に組み込む |
| フルスコープの実装規模が過大 | 完成しない | Strangler Fig で段階導入。Phase1(OIDC) で先に価値を出す |
| 既存資産からの移行困難 | 切替できない | PBKDF2 パスワードハッシュ互換、既存クライアント/セッションの後方互換を設計に織り込む |

## 8. 段階導入ロードマップ（Strangler Fig）

Keycloak と**並走**させ、少しずつ移行する。ビッグバン置換はしない。

- **Phase 0 — リスクスパイク（最優先）**: 作る前に最大リスクを潰す
  1. SAML XML-DSig を Rust(FFI 含む)で安全に検証/署名できるか
  2. WASM プラグインホスト（extism）でマッパーが書けるか
  3. ステートレス + Redis/Postgres セッションモデルの性能
- **Phase 1 — OIDC/OAuth2 コア + 設定 IaC + Passkey**: 最も価値が高く Rust で達成可能。ステートレス・no-Infinispan を最初から。
- **Phase 2 — 外部IdP連携(OIDC/SAML as client) + LDAP federation**
- **Phase 3 — SAML IdP / FAPI / CIBA / Token Exchange / 認可サービス**（重い順を後ろに）
- **全期間共通 — 移行互換**: PBKDF2 ハッシュ互換、既存クライアント/セッションの後方互換。

## 9. 検討した代替案

- **既存モダン OSS への乗り換え（Zitadel / Ory / Authentik / Casdoor）**: 課題2・3・4の多くを既に解決済みで実装リスクは最小。今回は独自要件のため自作を選択するが、**自作 GO/NO-GO の判断材料として常に対置**する（Phase0 後に再評価）。
- **Go での自作**: この領域のデファクト（Ory/Zitadel/Casdoor）で OIDC(`fosite`)/SAML ライブラリが成熟。Rust より実装リスクは低いが、チームの言語方針で Rust を採用。
- **ビッグバン置換**: リスク過大のため不採用。Strangler Fig を採用。

## 10. 未決事項（後続 ADR で扱う）

- イベントソーシング採用の是非（ADR-0002 候補）
- マルチテナント設計
- トークン形式の Keycloak 互換方針
- SAML を「FFI 実装」か「別コンポーネント分離」か「後送り」かの最終決定（Phase0 の結果次第）
