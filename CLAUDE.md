# sharecmd

## Build

`main.go` is generated. Never edit it by hand: change `main.sh` and its subscripts, then run `./build.sh`.

- `build.sh` runs `./main.sh | gofmt > ./main.go` with `pipefail` set.
- It needs the `orc` repo checked out next to this one (`../orc/lib/src/main/bash/com/koreyhinton/nsmap`). `bind` comes from there.
- After any change, run `./build.sh && go vet ./... && go test -race ./...`.
- `server_test.go` tests the server end to end by building and running the binary, since the server is inlined in `main()`. `integration_test.go` runs the server with two real clients. When you change server or client behavior, update or add a test. CI runs the same checks on pull requests into `main` (`.github/workflows/test.yml`).

## Server code: imperative, readable start to end

Server code is written as imperative orc subscripts, inlined into `main`, not as Go functions or methods. Someone reading the generated server should be able to read it from top to bottom in order, like literate programming.

- Put each server step in its own subscript (`main-<name>.sh`), inlined where it runs. Don't add server functions or methods.
- A step used in several places (`main-send.sh`, `main-notify-end.sh`, `main-remove.sh`) is one subscript inlined at each call site. If it should only run sometimes, bind a `When` bool and gate its steps on `${!when}`, rather than wrapping the call site in an `if`.
- A loop is driven by a flag, not `break`: `for reading := claimed; reading; { ... }`, where the body sets `reading = false`. Put a long loop body in its own subscript (`main-handle-ws-read.sh`).
- No `defer`: inlined code runs inside the enclosing handler, so a `defer` would wait until the handler returns. Unlock explicitly.
- This applies to server code only. Leave client code (`runClient`, `Sim`) and `demo/` in their current form.

### Control flow inside a subscript

- No `return`, `break`, `continue` or `goto`. Execution always reaches the end of the subscript.
- No `if` nested inside another `if`. Explicit `if` statements are fine.
- Instead, assign named bools and test them in flat `if`s with compound conditions:

  ```go
  isPost := r.Method == http.MethodPost
  hasWaiting := s.waiting != nil
  if isPost && hasWaiting { ... }
  if isPost && !hasWaiting { ... }
  ```

- When a lock must cover several steps, take it in one `if` and release it in a later `if` with the same condition. Add a comment saying so.
- When Go needs a func value as a callback (for example `time.AfterFunc`), define the closure at the top level of the subscript and pass it in. Put the closure's body in its own subscript, named after the parent (`main-handle-match.sh` → `main-handle-match-expire.sh`), so its `if`s are top-level in that file and not indented inside the closure. Bind the closure's parameters and any names it uses from the parent (pass a bound name on as `${!s}`):

  ```bash
  export ${v}xp_M=m
  export ${v}xp_S=${!s}
  ...
  	expire := func(m *Match) {
  		` ./main-handle-match-expire.sh ${v}xp_ `
  	}
  ```

  Go indents with tabs, which look wide in Emacs, so this keeps the nesting shallow where the code is written.

### Subscript format and binding

```bash
#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} R W S

cat << EOF
	first line has one leading tab
	other lines indent from that base (one more tab per block level)
EOF
```

- The caller exports one name per bound variable, then inlines the subscript:

  ```bash
  export ${v}hdl_mtch_R=r
  ...
  	` ./main-handle-match.sh ${v}hdl_mtch_ `
  ```

- Inside the subscript, refer to bound variables as `${!r}`, `${!w}`, `${!s}`.
- Bind every local from the calling scope that the subscript uses. Package-level names don't need binding: imports, types, and globals such as `upgrader`.
- Prefer binding one struct (such as `S` for `*Server`) over binding many separate variables.
- Package-level server values that `main.sh` doesn't use directly go in `models.go`.
- The heredoc is unquoted, so escape `$` and backticks in Go code (or keep them out of it). Leave `%s` format verbs alone when replacing a bound `s`.
