# sharecmd

## Build

`main.go` is generated. Never edit it by hand: change `main.sh` and its subscripts, then run `./build.sh`.

- `build.sh` runs `./main.sh | gofmt > ./main.go` with `pipefail` set.
- It needs the `orc` repo checked out next to this one (`../orc/lib/src/main/bash/com/koreyhinton/nsmap`). `bind` comes from there.
- After any change, run `./build.sh && go vet ./... && go test -race ./...`.
- `server_test.go` tests the server end to end by building and running the binary, since the server is inlined in `main()`. `integration_test.go` runs the server with two real clients. When you change server or client behavior, update or add a test. CI runs the same checks on pull requests into `main` (`.github/workflows/test.yml`).

## Server code: imperative, readable start to end

Server code is written as imperative orc subscripts, inlined into `main`, not as Go functions or methods. The server is one loop in one goroutine that handles one match at a time: each pass of the loop either handles one connection while players join or plays one turn once they're matched, chosen by `if !matched { ... } else { ... }`. Someone reading the generated server should be able to read it from top to bottom in order, like literate programming.

- Put each server step in its own subscript (`main-<name>.sh`). Don't add server functions or methods.
- `main.sh` calls every step directly, in order, and steps are leaves: a subscript never inlines another subscript. The server loop in `main.sh` is the whole outline of the server: a list of steps, with the loops and `if`s that decide which steps run.
- Join steps are named `main-join-*.sh` and play steps `main-play-*.sh`. A step used in several places (`main-write-frame.sh`, `main-player-conn.sh`, `main-player-sent.sh`, `main-player-close.sh`, `main-match-end.sh`) is one subscript called at each place.
- A step that runs only in some cases gets an `if` around its call in `main.sh` (`if isWS { ... }`, `if ended && connected { ... }`). It doesn't bind a bool to cancel itself. That includes shared steps: `main-write-frame.sh` is called as `if connected { ... }` or `if taken { ... }`.
- A step can declare variables that later steps use. Go scoping still applies: a variable declared inside an `if` or loop in `main.sh` is gone after it. So declare a value that's needed after the block in an earlier step, outside it. `main-join-read-request.sh` declares `taken`, and `main-handle-ws.sh` sets it inside `if isWS`.
- A loop is driven by a flag, not `break`: `for reading := true; reading; { ... }`, where a step sets `reading = false`. The loop sits in `main.sh`, and its body is a list of steps.
- No `defer`: inlined code runs inside `main`, so a `defer` would wait until the server exits.
- No callbacks, goroutines or locks on the server. Code that would wait on a timer checks a deadline in the loop instead (`main-join-accept.sh` sets the listener's deadline to the match's join deadline). The server speaks HTTP and websockets itself, with `net`, `net/http` request parsing and hand-written frames, so it doesn't use gorilla.
- This applies to server code only. Leave client code (`runClient`, `Sim`) and `demo/` in their current form.

### Control flow

- No `return`, `break`, `continue` or `goto`. Execution always reaches the end of the subscript.
- No `if` whose body is only another `if`, in a subscript or in `main.sh`. That's one condition split in two, so write it as one: `if a && b { ... }`, not `if a { if b { ... } }`. An `if` can contain other `if`s when its body has more steps than that, as in the server loop:

  ```go
  if accepted {
  	` ./main-join-read-request.sh ${v}jn_ `
  	if isMatch {
  		` ./main-handle-match.sh ${v}jn_ `
  	}
  	...
  }
  ```

- To run exactly one of two steps, use `if`/`else` on one bool, as the server loop does with `matched`. The `else` shows that only one branch runs, so a change one branch makes to the bool is only seen on the next pass.
- Inside a step, assign named bools and test them in flat `if`s with compound conditions:

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
. ${NSMAP}/bind ${v} S Req Taken

cat << EOF
	first line has one leading tab
	other lines indent from that base (one more tab per block level)
EOF
```

- `main.sh` exports one name per bound variable, then calls the subscript:

  ```bash
  export ${v}jn_Req=req
  ...
  	` ./main-handle-match.sh ${v}jn_ `
  ```

- Steps that run together share one namespace: `jn_` for join, `js_` for join's per-player start and end notices, and `pl_` for play. `main.sh` exports only the names it uses itself (`accepted`, `ready`, `p`, ...). Every other bound name keeps its namespaced name in `main.go` (`mn_jn_Body`), so it needs no export. Export an alias when two bound names must be the same variable: `export ${v}jn_Msg=${v}jn_TakenMsg` makes `main-write-frame.sh`'s `Msg` the taken message, and `export ${v}js_M=${v}jn_M` gives the notice loop join's match. In a namespace, a bound name means one variable in every step that uses it. When two steps need the same name for different variables, give one of them a more specific name (`main-read-frame.sh` binds `ReadErr`, so it doesn't clash with `main-write-frame.sh`'s `Err`), or use a separate namespace (`js_`, where `Conn` is player p's connection, not the connection being joined).
- Inside the subscript, refer to bound variables as `${!s}`, `${!req}`, `${!taken}`. `bind` lowercases names and turns CamelCase into snake_case (`ContentType` → `${!content_type}`).
- Bind every local from the calling scope that the subscript uses. Package-level names don't need binding: imports, types, and constants such as `maxMessage`.
- Also bind every variable a step declares for a later step or for `main.sh` to use, and declare it through its bound name: `${!code}, ${!body} := ...`, not `code, body := ...`. Then the step works whatever name `main.sh` maps it to, or with no export at all (`bind` then names it after the namespace, such as `mn_jn_Body`). Variables used only inside the step can keep plain names.
- Prefer binding one struct (such as `S` for `*Server`) over binding many separate variables.
- Package-level server values that `main.sh` doesn't use directly go in `models.go`.
- The heredoc is unquoted, so escape `$` and backticks in Go code (or keep them out of it). Leave `%s` format verbs alone when replacing a bound `s`.
