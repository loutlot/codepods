# Codepods

日本語 · [English](README.md)

![EarPods で Codex を操作する Codepods](Assets/codepods-hero-ja.png)

有線 EarPods から macOS 版 ChatGPT アプリ（Chat / Work / Codex）を操作するメニューバーアプリです。ChatGPT が最前面のときだけ EarPods のリモコンを使い、ほかのアプリでは通常のメディア操作に戻ります。

| EarPods のボタン | ChatGPT での動作 |
| --- | --- |
| `＋` / `－` | **最近のモデル**の最大3件を順番に切り替え |
| 中央を1回押す | 音声入力を開始。もう一度押すと停止 |

メニューバーには選択中のモデルと音声入力のオン／オフを表示します。アプリの言語は Mac の言語設定に従い、英語・日本語・韓国語・簡体字中国語に対応しています。それ以外の言語では英語を表示します。

## ダウンロードとインストール

1. [GitHub Releases](https://github.com/loutlot/codepods/releases/latest) から `Codepods-0.1.0-macos-arm64.zip` をダウンロードします。
2. ZIP を展開し、`Codepods.app` を **アプリケーション** フォルダへ移します。権限を保持しやすいよう、以降は同じ場所から起動してください。
3. この配布版は **Developer ID 署名と Apple の公証を受けていません**。初回起動時に macOS がブロックしたら、起動を試みた後に **システム設定 → プライバシーとセキュリティ →「このまま開く」**を選び、再度「開く」を押してください。[Apple の案内](https://support.apple.com/ja-jp/guide/mac-help/mh40616/mac)
4. Codepods メニューの **「設定と権限…」**を開きます。各ボタンからアクセシビリティと入力監視の設定を開き、必要なら設定画面の Codepods アイコンをアプリ一覧へドラッグして、両方のスイッチをオンにします。
5. 3.5 mm または USB-C の有線 EarPods を接続します。認識状態は設定画面に表示されます。

アクセシビリティは ChatGPT の操作部を読み取り、操作するために使います。入力監視は EarPods のボタンを取得し、ChatGPT 操作中に中央ボタンがほかのメディアを再生しないようにするために使います。どちらも利用者による許可が必要です。アドホック署名の更新版では、再許可が必要になる場合があります。

## 動作環境と制限

- macOS 14 以降の Apple Silicon Mac。現在の配布版は arm64 専用です。
- 3ボタンリモコン付きの有線 Apple EarPods（3.5 mm または USB-C）。
- 現行の ChatGPT デスクトップアプリ（`com.openai.codex`）。画面上の操作部を利用するため、将来の ChatGPT の UI 変更には Codepods の更新が必要になる場合があります。
- 中央ボタンは ChatGPT の押している間だけ動く音声入力ショートカットを切り替えます。ほかのアプリでは通常のメディア操作を維持します。

Codepods はローカルで動作し、テレメトリは送信しません。ソースコードはこのリポジトリで公開しています。自分でビルドする場合は Xcode をインストールして `./build.sh` を実行してください。アプリは `dist/Codepods.app` に生成されます。
