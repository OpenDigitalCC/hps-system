# ADR 0004 — lighttpd replaces nginx and fcgiwrap on the IPS

- Status: accepted
- Date: 2026-11-09
- Tags: ips, web, cgi, logging

## Context

The IPS web server must serve static files with range support, run the
Bash CGI scripts, bind one address and log to syslog. nginx cannot run
CGI itself: it needed `spawn-fcgi`, `fcgiwrap`, a unix socket under
supervisor and a second program block.

## Decision

Owner ruling (2026-11-09): lighttpd does all four in one process.
`create_config_lighttpd` writes `lighttpd.conf` in the cluster services
directory; supervisor runs `lighttpd -D -f <conf>`. mod_cgi runs the
`.sh` scripts under `/cgi-bin/` and `/api/` with `/bin/bash`. The
locations are unchanged: `/`, `/cgi-bin/`, `/api/`, `/distros/`,
`/packages/`, `/nixos/`, `/nix-cache/` (no listing; `nix-cache-info` as
`text/plain`). Replaces: the nginx config generator, the `nginx` and
`fcgiwrap` supervisor programs, and the `nginx`, `spawn-fcgi` and
`fcgiwrap` image packages.

## What to watch

- CGI environment delivery: scripts read `REQUEST_METHOD`,
  `QUERY_STRING`, `CONTENT_LENGTH`, `REMOTE_ADDR`, `HTTP_X_HPS_MAC` and a
  stdin body of up to 256 KiB (`server.max-request-size` is 4 MiB).
  Verify on the live IPS; `Status:` header lines are honoured by mod_cgi.
- Ranges for netboot artefacts (initrds of about 1.5 GB):
  `server.range-requests = "enable"`; check a `Range:` GET on `/nixos/`.
- Syslog: error and access log go to syslog with ident `lighttpd`, which
  rsyslog files under `ips/lighttpd/`. CGI stderr lands in the error log.
- The server drops to `www-data`, as fcgiwrap did.
