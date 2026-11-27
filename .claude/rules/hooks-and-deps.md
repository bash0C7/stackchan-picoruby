---
paths:
  - ".claude/**"
  - "tools/hooks/**"
  - "tools/check_deps_pushed.sh"
  - "acceptance/lock.yml"
---

# Claude Code Hooksと依存ガード制約

## Claude Code Hook実測挙動

- `matcher`はtool名だけに当たる。`"Bash(git push*)"`のような形は文字列`Bash`への非anchor正規表現になり一致しない。handler側の`"if"`（permission-rule構文）は前方一致なので`git -C <dir> push`や`/opt/homebrew/bin/git push`を取りこぼす。取りこぼし不可のguardは`matcher: "Bash"`だけにしてscript側で判定する。
- `.claude/settings.json`のhook変更はsession再起動なしで次のtool callから有効。
- exit 2でtool callをblockする。**block時に表示されるのはstderrのみ**でstdoutは捨てられるため、拒否理由は必ずstderrに出す。

## `tools/hooks/pre_push_guard.sh`

- pinを公開するpushはguard自身に止められるため`STACKCHAN_DEPS_GUARD=off`を前置する。
- guardが届かない範囲: `--pins-only`はpinのみ検査するため腐ったgem refや編集済みvendored treeはfull runでしか捕まらない。`reachable_from_github`はfetch前にremote-tracking refで答えるためforce-pushで消えたbranchはCI fresh cloneまで公開済みに見える。fork長寿命integration branchはbranch protection対象外で検出のみ。

## `tools/hooks/device_guard.sh`

- **常時ブロック（main/subagent問わず）**:
  - `/dev/cu.usbmodem*`・`/dev/tty.usbmodem*`への生`cat`
  - `idf.py flash` / `idf.py erase_flash` / `esptool`直接書き込み・消去
  - `build/repos`への`rm -rf`
- **main contextのみブロック（hook stdin JSONに`"agent_id"`が無い場合）**:
  - `r2p2:boards`・`r2p2:flash_identity`・`r2p2:qemu_check`・`bin/capture-with-pty`経由の`r2p2:monitor`を除く`rake r2p2:*`
  - `rake acceptance:deploy`・`rake acceptance:app`
- `context: fork`のSkillおよびsubagent経由の実行には`"agent_id"`が付与されるため自動通過する。緊急overrideは`STACKCHAN_DEVICE_GUARD=off`を前置する。
