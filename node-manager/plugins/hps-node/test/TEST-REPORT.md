# Test report: hps-node (ce-agent-plugins)
Generated: 2026-07-08T12:44:43Z

  PASS  no subcommand -> nonzero exit (usage)
  PASS  unknown subcommand -> nonzero exit (usage)
  PASS  help -> zero exit
  PASS  missing bundle -> exit 2
  PASS  ping -> zero exit
  PASS  run-init dispatches n_init_run
  PASS  set-status dispatches n_remote_host_variable
  PASS  opensvc-join dispatches n_opensvc_join
  PASS  vm-create dispatches n_vm_create
  PASS  set-status without state -> exit 2
  PASS  opensvc-join without token -> exit 2
  PASS  vm-create without spec -> exit 2

Passed: 12  Failed: 0
VERDICT: PASS
