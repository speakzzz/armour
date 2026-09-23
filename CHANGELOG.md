# Changelog — speakz-armour

All notable changes in this round of fixes. Dates reflect the `speakz-armour`
branch. Three of these are security fixes; see **Security** below and upgrade
promptly.

Every change ships with a `tcltest` suite under `tests/` (run `./tests/run.sh`).
The suites load the real procedures out of `armour.tcl`, so they fail if the
code regresses. 144 tests across 12 suites at time of writing.

---

## Security

- **Remote command execution via `conf` / `deploy` (level 500).**
  Config files were written with `exec sed -i "s|…|<value>|"`. A value
  containing `|` could close the expression and add GNU sed's `e` command,
  running an arbitrary shell command as the eggdrop user
  (`conf <setting> x|;e <command>;#`). Config writes are now done in Tcl with an
  atomic temp-file rename; nothing is passed to a shell. Values are written as
  quoted Tcl literals so they cannot execute when the config is sourced at
  startup. `deploy` now validates the bot name, network name, setting names and
  setting values. *(Requires a level-500 account.)*

- **Privilege escalation via unescaped settings SQL (level 450).**
  `modchan` built its settings `UPDATE` with the value unescaped (the adjacent
  `INSERT` escaped it; the `UPDATE` did not), allowing a channel manager to
  inject SQL — e.g. raise their own global level to 500. The same unescaped
  pattern affected `moduser`/`set` for `city` and `tz`. All settings writes now
  pass values through `db:escape`. *(Requires a level-450 account.)*

- **Database/file truncation via the login command (pre-auth).**
  `userdb:encrypt` hashed passwords with `exec echo $pass | md5sum`. Because
  `exec` treats a leading `>` as a redirection, an unauthenticated user could
  send `login <user> >armour/db/<bot>.db` and truncate any file the bot could
  write. Hashing is now done in-process with tcllib `md5`; existing stored
  hashes remain valid. *(Exploitable pre-authentication.)*

- **Password written to the command log.** `set pass <password>` logged the raw
  command. `userdb:cmd:set` computed a masked value ("pass") specifically to keep
  the password out of the log, then logged the raw argument anyway. The command
  log is readable via `showlog` (level 500). It now logs the masked value.
  *(Existing `SET` rows in `cmdlog` may still contain passwords — worth clearing.)*

- **Secret disclosure via `conf`.** An exact query for a config-stored secret
  that holds a value — e.g. `conf ask:token`, or any set API key — printed the
  value to the channel; the protected list previously applied only to
  mask/pattern queries. Secrets are now hidden on exact queries and
  "already set" replies over non-DCC, covering `auth:pass`, `auth:totp`, all
  `*:key`/`*:token`/`*:org` settings (including `dronebl:key`, previously
  missing from the hand-written list), and any future
  `*:key`/`*:pass`/`*:token`/`*:secret`/`*:totp`.
  (Note: `auth:pass` is stored per-user in the database and is empty in the
  config, so `conf auth:pass` never reached the printing path on a normal
  setup — the disclosure applied to config-stored secrets with a value.)

---

## Fixed

### IPv6 / networking

- **`cidr:match` mishandled compressed IPv6.** The `::` expansion counted
  colons incorrectly and produced 112 bits instead of 128, so a blacklist entry
  matched or missed depending on how the address was written. IPv4-mapped
  addresses (`::ffff:…`) threw. IPv4 matching gained input validation
  (`1.2.3.260` and malformed input no longer match or throw). Rewritten around a
  single `ipv6:expand` helper.

- **`ip:reverse` truncated compressed IPv6** the same way, producing 28-nibble
  names instead of 32. This built the query name for **every DNSBL and Team Cymru
  lookup**, so IPv6 clients silently skipped DNSBL checks and returned no country
  or ASN. Now shares `ipv6:expand`.

- **`geo:ip2data` mis-parsed multi-origin ASN records.** `split $answer " | "`
  split on a character set rather than a delimiter, so a prefix announced by
  more than one AS shifted every field and blanked the country/ASN. Now parses
  on the pipe and validates the field count.

### WHO / scanning

- **`raw:genwho` (352) parsing.** The reply was parsed as a Tcl list, so a
  realname containing an unbalanced brace or quote threw and the client was
  **never scanned** — a way to bypass all checks. It also dropped the first word
  of every realname (wrong field index) and wrapped the realname in extra list
  quoting (the `{{{}}}` seen in logs). Now parsed as text via a shared
  `raw:parse:352`; realnames arrive verbatim.

- **`userdb:raw:genwho` (352)** shared the same unsafe list-parsing and had its
  channel field omitted (shifting every field by one). Now uses
  `raw:parse:352`.

- **`arm::scan` name shadowing.** A hotfix helper used the unqualified `scan`
  command inside the `arm` namespace, which resolves to the bot's own
  `arm::scan` and aborted the scan of any IPv6 client reaching a CIDR entry.
  Qualified as `::scan`.

### TOTP (X login)

- **TOTP token generation.** The X login shelled out to `oathtool --totp
  <secret>`, which reads its argument as **hex** unless given `-b`; a base32
  secret (as documented) was rejected, aborting the login, and a base32 secret
  using only hex characters silently produced a wrong code. The secret was also
  exposed on the process command line. Now generated in-process with the
  bundled RFC 6238 implementation; `oathtool` is no longer required. Verified
  against RFC 4226/6238 vectors and `oathtool`.

### Passwords

- **`newpass` / `login` lockout.** The two commands extracted the password
  differently (`[lrange]` vs `[join [lrange]]`), so any password containing
  `$ ; [ ] \ "` or a leading `#` was hashed one way when set and another way at
  login — locking the user out. Passwords are now taken verbatim everywhere via
  new `arg:word` / `arg:tail` helpers. Hashes stored by older versions are still
  accepted (both legacy forms are tried), without rewriting them.

- **Silently altered passwords.** Backslashes, braces and quotes were stripped
  from passwords (`back\slash` became `backslash`). Now stored as typed.

- **`randpass`** could emit `\` (breaking generated passwords) and never chose
  the last character of its set (off-by-one). Fixed.

- **Remote `logout`** with another user's password threw (read an unset
  variable) and would have logged out the requester instead of the target. Now
  logs out the target.

### Command text (reasons, topics, messages, values)

- **`kick`, `ban`, `topic`, `say`, `black`, `add`** list-parsed their
  reason / topic / message / value, which rewrote `\ { } "`. They now use
  `arg:word` / `arg:tail` and preserve the text exactly (inner spacing kept;
  ends trimmed). `db:add` and the entry readers were made list-safe to match.
  *(An unbalanced `{` or `"` still makes these commands error in their logging
  step — see Known open items.)*

- **`set` values** (greet, city, email, …) are stored as typed.

### Command handlers (robustness)

- **Log lines no longer list-parse the argument.** 74 log lines across the
  command handlers built their entry with `[join $arg]`, so text containing an
  unbalanced `{` or `"` still threw at the logging step, at the end of the
  command. All now use `[string trim $arg]`.

- **`say -a`** terminated the CTCP ACTION with `\002` (bold) instead of `\001`,
  emitting a malformed action.

- **`mod`** stored the SQL-escaped value in the in-memory entries dict, so an
  edited reason like `don't spam` showed as `don''t spam` until the next restart
  (the database row was correct). Its argument parsing is now verbatim too.

### Autotopic

- **`raw:topic` (332)** read the channel topic back through `[lrange]`, altering
  topics containing `[ $ \` or runs of spaces, so autotopic re-set the topic on
  **every check** even when it already matched. The topic is now read verbatim.

### `conf` / `deploy` bugs (beyond the security fix)

- `&` in a `conf` value was replaced with the previous line contents (sed treats
  `&` specially); now stored literally.
- `deploy`'s `{realname=I am a string}` multi-word syntax never worked (two
  `join`s flattened it); fixed.
- `deploy`'s per-setting network override used `lsearch` with its arguments
  reversed and was always ignored; corrected to `lsearch -glob`.
- `conf` decided exact-setting vs mask by fetching the value, so a mask query
  (`conf *auth*`) made `cfg:get` emit a spurious `config error -- setting not
  found` to the report channel, and an exact query for an empty-by-default
  setting (nine ship empty, including `auth:pass`) was misreported as "no
  matching setting(s) found". The gate now tests existence (`info exists`), so
  masks raise no error and empty settings route to the exact branch. *(Both
  pre-existing; surfaced while verifying the secret-hiding above.)*

---

## Added

- **`tests/`** — a `tcltest` suite for every fix above, plus `tests/run.sh` to
  run them all (exits non-zero on failure). Suites: `cidr`, `who`, `topic`,
  `totp`, `encrypt`, `auth`, `reason`, `sqli`, `conf`.
- **`add` now reports what a new entry will do.** After a successful
  host/user/regex add it prints advisory notes (never blocking the add):
  which users currently on the channel the entry matches, which entries of the
  opposite list type it overlaps, and — for a whitelist host entry — which
  active channel `+b` bans would still block it. For a global (`*`) entry the
  notes aggregate across every channel the bot is on (capped at 20), so they
  reflect everywhere the entry actually applies; adding a global entry by
  private message reports on all channels too. Repeating the add with
  `-unban` lifts those bans (via `mode:unban`, honouring the channel's
  configured method). The `-unban` flag is stripped before parsing, so it never
  lands in the value, action or reason.

- Helper procedures: `ipv6:expand`, `ipv4_to_binary`, `raw:parse:352`,
  `arg:word`, `arg:tail`, `conf:sensitive`, `conf:literal`, `file:setline`,
  `file:hasline`, `entry:matches`, `add:matchusers`, `add:conflicts`,
  `add:blockingbans`.

---

## Upgrade notes

- **Existing password hashes keep working.** No user needs to reset a password.
  The web dashboard's login was not changed, so a user whose password contains
  `$ ; [ ] #` may need to `newpass` again before web login accepts it.
- **IPv6 clients are now actually scanned** (DNSBL / country / ASN). Country- and
  ASN-based list entries that never matched IPv6 clients will start matching —
  review broad entries before deploying to a busy channel.
- **TOTP secret must be base32.** If the bot logs into X with TOTP and the
  secret was stored as hex (the only format the old code accepted), convert it:
  `echo -n '<HEX>' | xxd -r -p | base32`, and put the result in `auth:totp`.
- `oathtool` is no longer a runtime dependency.
- Back up `db/<bot>.db` before upgrading, given the security fixes.

---

## Not included / known open items

These were identified but not changed in this round:

- Temporary bans do not survive a restart. A `kickban` schedules its unban with
  eggdrop's `timer`, and `mode:rem:b` deletes the matching (auto) blacklist
  entry when that ban is lifted — so in normal operation floodnet's
  `(auto) join flood detected` entries clean themselves up. But timers are lost
  on restart or rehash, and nothing re-arms them or sweeps expired bans at
  startup, so any ban pending at that moment stays on the channel and its entry
  stays in the database indefinitely. Recording ban expiry times and re-arming
  (or sweeping) at startup would close this.
- `cfg(ircbl:net)` is referenced by the IRCBL *delete* query but is not defined
  anywhere, so with `cfg(ircbl)` enabled a removal logs a "setting not found"
  config error and sends an empty network field. Dormant while IRCBL is off.

- **TLS certificate verification is not enabled** on any HTTPS connection,
  including the GitHub-based updater. Traffic interception could deliver
  malicious update code. No account required — highest-priority remaining item.
- Most SQL is still built by string interpolation rather than bound parameters.
- Passwords are unsalted MD5 (a salted, iterated scheme is the next step; the
  new matcher makes silent migration on login straightforward).
- Updates have no signature/checksum verification.
- Unbounded growth of some per-nick state arrays; no RFC-1459 casemapping; the
  ircu `raw:who` (354) parser has the same list-parsing issue as 352; the
  bundled `openai` plugin has JSON-escaping and SSRF issues (dormant unless
  loaded).
