#!/bin/sh
payload=$(cat)

case "$payload" in
  *'"tool_name":"Bash"'*) ;;
  *) exit 0 ;;
esac

rest=${payload#*'"command":"'}
cmd=${rest%%'","description":"'*}
cmd=${cmd%%'"}'*}

case "$cmd" in
  *STACKCHAN_DEVICE_GUARD=off*) exit 0 ;;
esac

case "$cmd" in
  "git commit"*|"git log"*|"git show"*|"grep "*|"rg "*)
    case "$cmd" in
      *";"*|*"&&"*|*"||"*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

case "$cmd" in
  *"cat "*"/dev/cu.usbmodem"*|*"cat "*"/dev/tty.usbmodem"*)
    printf '%s\n' 'BLOCKED: Raw cat on /dev/{cu,tty}.usbmodem* goes silent on USB CDC re-enumeration. Use bin/capture-with-pty via stackchan-device-diagnose.' >&2
    exit 2
    ;;
  *"idf.py "*"flash"*|*"idf.py "*"erase"*|*"esptool"*"write_flash"*|*"esptool"*"write-flash"*|*"esptool"*"erase_region"*|*"esptool"*"erase-region"*|*"esptool"*"erase_flash"*|*"esptool"*"erase-flash"*)
    printf '%s\n' 'BLOCKED: Direct idf.py flash or esptool flash/erase bypasses the QEMU boot gate and partition-table lookup. Use /stackchan-device-firmware or stackchan-device-app.' >&2
    exit 2
    ;;
  *"rm "*"-rf"*"build/repos"*|*"rm "*"-fr"*"build/repos"*)
    printf '%s\n' 'BLOCKED: build/repos/ contains shallow clones whose commits cannot be recovered after rm -rf. Use tools/check_deps_pushed.sh or git branch keep-<sha>.' >&2
    exit 2
    ;;
esac

case "$payload" in
  *'"agent_id":'*) exit 0 ;;
esac

case "$cmd" in
  *rake*r2p2:*)
    for tok in $cmd; do
      clean=${tok%%[;\&|]*}
      case "$clean" in
        r2p2:boards|r2p2:flash_identity|r2p2:qemu_check) ;;
        r2p2:monitor)
          case "$cmd" in
            *bin/capture-with-pty*) ;;
            *)
              printf '%s\n' 'BLOCKED: Run r2p2:monitor through bin/capture-with-pty or stackchan-device-diagnose.' >&2
              exit 2
              ;;
          esac
          ;;
        r2p2:*)
          printf '%s\n' "BLOCKED: Do not run $clean directly from main context. Use stackchan-device-app, stackchan-device-diagnose, or /stackchan-device-firmware." >&2
          exit 2
          ;;
      esac
    done
    ;;
esac

case "$cmd" in
  *rake*acceptance:deploy*|*rake*acceptance:app*)
    printf '%s\n' 'BLOCKED: Run acceptance:deploy and acceptance:app in a subagent via /stackchan-device-acceptance, not directly in main context.' >&2
    exit 2
    ;;
esac

exit 0
