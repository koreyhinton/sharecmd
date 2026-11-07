# sharecmd

## Build

`main.go` is generated. Never edit it by hand: change `main.sh` and its subscripts, then run `./build.sh`.

- `build.sh` runs `./main.sh | gofmt > ./main.go` with `pipefail` set.
- It needs the `orc` repo checked out next to this one (`../orc/lib/src/main/bash/com/koreyhinton/nsmap`). `bind` comes from there.
- After any change, run `./build.sh && go vet ./... && go test -race ./...`.
- `server_test.go` tests the server end to end by building and running the binary, since the server is inlined in `main()`. `integration_test.go` runs the server with two real clients. When you change server or client behavior, update or add a test. CI runs the same checks on pull requests into `main` (`.github/workflows/test.yml`).

## Server code: imperative, readable start to end

Server code is written as imperative orc subscripts, inlined into `main`, not as Go functions or methods. The server is one loop in one goroutine that handles one match at a time: each pass of the loop either handles one connection while players join (`main-join.sh`) or plays one turn once they're matched (`main-play.sh`), chosen by `if !matched { ... } else { ... }`. Someone reading the generated server should be able to read it from top to bottom in order, like literate programming.

- Put each server step in its own subscript (`main-<name>.sh`), inlined where it runs. Don't add server functions or methods.
- A step used in several places (`main-send.sh`, `main-notify-end.sh`, `main-write-frame.sh`) is one subscript inlined at each call site. If it should only run sometimes, bind a `When` bool and gate its steps on `${!when}`. A whole step that runs in only one case, such as `main-join.sh` and `main-play.sh` in the server loop, can instead be inlined inside an `if` or `else` at its call site.
- A loop is driven by a flag, not `break`: `for reading := true; reading; { ... }`, where the body sets `reading = false`. Put a long loop body in its own subscript (`main-read-cmds.sh`).
- No `defer`: inlined code runs inside `main`, so a `defer` would wait until the server exits.
- No callbacks, goroutines or locks on the server. Code that would wait on a timer checks a deadline in the loop instead (`main-join.sh` sets the listener's deadline to the match's join deadline). The server speaks HTTP and websockets itself, with `net`, `net/http` request parsing and hand-written frames, so it doesn't use gorilla.
- This applies to server code only. Leave client code (`runClient`, `Sim`) and `demo/` in their current form.

### Control flow inside a subscript

- No `return`, `break`, `continue` or `goto`. Execution always reaches the end of the subscript.
- No `if` whose body is only another `if`. That's one condition split in two, so write it as one: `if a && b { ... }`, not `if a { if b { ... } }`. An `if` can contain other `if`s when its body has more steps than that, as in the server loop:

  ```go
  if !matched {
  	// main-join.sh: several steps, some with their own ifs
  } else {
  	// main-play.sh
  }
  ```

- To run exactly one of two steps, use `if`/`else` on one bool, as the server loop does with `matched`. The `else` shows that only one branch runs, so a change one branch makes to the bool is only seen on the next pass.
- Instead, assign named bools and test them in flat `if`s with compound conditions:

  ```go
  isPost := req.Method == http.MethodPost
  isNew := isPost && s.match == nil
  if isPost && isNew { ... }
  if isPost && !isNew { ... }
  ```

### Subscript format and binding

```bash
#!/bin/bash
v=${1}
# maps
. ${NSMAP}/bind ${v} S Req When

cat << EOF
	first line has one leading tab
	other lines indent from that base (one more tab per block level)
EOF
```

- The caller exports one name per bound variable, then inlines the subscript:

  ```bash
  export ${v}mt_Req=req
  ...
  	` ./main-handle-match.sh ${v}mt_ `
  ```

- Inside the subscript, refer to bound variables as `${!s}`, `${!req}`, `${!when}`. `bind` lowercases names and turns CamelCase into snake_case (`ContentType` → `${!content_type}`).
- Bind every local from the calling scope that the subscript uses. Package-level names don't need binding: imports, types, and constants such as `maxMessage`.
- Prefer binding one struct (such as `S` for `*Server`) over binding many separate variables.
- Package-level server values that `main.sh` doesn't use directly go in `models.go`.
- The heredoc is unquoted, so escape `$` and backticks in Go code (or keep them out of it). Leave `%s` format verbs alone when replacing a bound `s`.
