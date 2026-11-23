# zig_clap

`zig_clap` is a command-line parser for Zig. The schema is a directory of CSV files, read at build time. The program asks for the result type, parses `argv`, and frees the lists the parser owns.

A flag, a number, a string, and a list are rows in `args.csv`. A subcommand is a row in `sub.csv` plus a child directory with the same two files. Leaving the command word off makes `command` null, which is the parent process. `-h` prints that level's help and exits.

```
src/cli/
  args.csv          options that apply before the command word
  sub.csv           serve
  desc.txt          optional prose for this level's help
  serve/
    args.csv        options that apply after `serve`
    sub.csv         header only: serve is a leaf
    desc.txt
```

The folder name is yours. `args.csv`, `sub.csv`, and `desc.txt` are the names the build looks up. Copy [`template/`](template/) to start a schema, or read [`src/args/`](src/args/) for a larger demo.

This package targets Zig `0.18.0-dev.1260+833623422` or newer. The version in `build.zig.zon` is `0.0.0`.

## Contents

- [Add the dependency](#add-the-dependency)
- [Write the program](#write-the-program)
- [Schema directory](#schema-directory)
- [args.csv](#argscsv)
- [sub.csv](#subcsv)
- [desc.txt](#desctxt)
- [Help](#help)
- [Errors](#errors)
- [Memory](#memory)
- [Limits](#limits)
- [Run the demo](#run-the-demo)
- [What this parser does not do](#what-this-parser-does-not-do)
- [Repository layout](#repository-layout)

## Add the dependency

From the program that will call the parser:

```sh
zig fetch --save git+https://example.com/you/zig_clap
```

Use the real git URL. A path on disk works too: `zig fetch --save ../zig_clap`.

In that program's `build.zig`, pass the schema directory. The option name is `args`. Without it, configuring a dependent package stops with `zig_clap needs .args = b.path("path/to/schema")`.

```zig
const clap = b.dependency("zig_clap", .{
    .target = target,
    .optimize = optimize,
    .args = b.path("src/cli"),
});
exe.root_module.addImport("zig_clap", clap.module("zig_clap"));
```

`src/cli` is only an example. Any directory that contains `args.csv` and `sub.csv` is valid. The build reads those files while configuring, and it depends on their contents, so the next `zig build` picks up a CSV edit.

This package's own `build.zig` defaults `.args` to `src/args` when it is the root package. That default is the demo. Dependents do not get it.

## Write the program

The calls are `commandType`, `parse`, and `deinit`. This program matches [`template/`](template/).

```zig
const std = @import("std");
const zig_clap = @import("zig_clap");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);

    // Parsed strings point into this iterator. On Windows the iterator owns
    // that buffer, so it has to outlive `args`.
    var iterator = try init.minimal.args.iterateAllocator(gpa);
    defer iterator.deinit();
    while (iterator.next()) |arg| try argv_list.append(gpa, arg);

    // A usage error prints help and exits. `try` surfaces out of memory.
    const args = try zig_clap.parse(gpa, argv_list.items);
    defer zig_clap.deinit(gpa, args);

    if (args.verbose) std.debug.print("verbose\n", .{});
    if (args.command) |command| switch (command) {
        .serve => |serve| {
            std.debug.print("port = {d}\n", .{serve.port});
            if (serve.output) |path| std.debug.print("log = {s}\n", .{path});
        },
    } else {
        std.debug.print("parent\n", .{});
    }
}
```

`commandType()` is the struct for the schema passed in `build.zig`. You rarely need to name it. `parse` takes the full `argv`, including `argv[0]`.

With the template schema the fields are:

| Invocation | What you get |
|---|---|
| `tool` | `verbose` is false and `command` is null |
| `tool -v` | `verbose` is true and `command` is null |
| `tool serve` | the `serve` tag, port 8080, log path null |
| `tool serve -p 9 -o app.log` | port 9, log path `app.log` |
| `tool -v serve -p 9` | the parent flag, then serve's port |

`-v` belongs to the parent, so it comes before `serve`. `-p` belongs to serve, so it comes after.

## Schema directory

Every command is a directory. The root is the directory you passed as `.args`. Each directory contains:

| File | Required | Role |
|---|---|---|
| `args.csv` | yes | Options for this command |
| `sub.csv` | yes | Child commands. Header only when there are none |
| `desc.txt` | no | Prose on this command's help page |

A row in `sub.csv` selects the child directory. The build does not scan the folder for extra directories. A folder that no row names is never read.

```
cli/
  args.csv
  sub.csv                 serve, and sync whose directory is s/
  desc.txt
  serve/
    args.csv
    sub.csv               header only
  s/
    args.csv              the `sync` command
    sub.csv
    push/
      args.csv
      sub.csv
```

That tree is three levels if `s/sub.csv` names `push`. The demo under [`src/args/`](src/args/) goes three levels down: `remote`, `sync`, `push` / `pull`.

## args.csv

Comments in [`template/args.csv`](template/args.csv) repeat this section so a copied file stands alone.

The columns are `short,long,type,arity,default,help`. A line that is blank or starts with `#` is ignored. The first row that starts with `short,` is the header and is ignored.

### Names

`short` is empty or one character. `v` is `-v`.

`long` is the `--name` and the result field. `dry-run` becomes `dry_run`. After that rewrite the name has to be a Zig identifier: letters, digits, and `_`, not starting with a digit. A row may omit `long` and keep `short`. The field is then that one character.

Duplicate long names, short characters, or field names are a compile error. When `sub.csv` has any rows, a field named `command` is a compile error. That name is the subcommand union.

At most 64 options per file.

### Types

| Cell | Result field for arity `1` |
|---|---|
| `bool` | `bool` |
| `u8` `u16` `u32` `u64` `usize` | that unsigned integer |
| `i32` `i64` | that signed integer |
| `[]const u8` | `[]const u8` |
| `?u16` | `?u16` |
| `?[]const u8` | `?[]const u8` |

Numbers are base 10. A bool value, when a value is parsed rather than a flag, is `true`, `false`, `1`, or `0`.

A leading `?` is on the value. For arity `1`, `?[]const u8` is one optional string. For `+` or `*`, the `?` is on the list: `?[]const u8` with `*` is `?[]const []const u8`, a null list or a list of strings. It is not a list of optional strings.

### Arity

| Cell | Meaning |
|---|---|
| `0` | Flag. The type's bare form must be `bool`. `-v`, `--verbose`, and a cluster such as `-qv` each store `true`. `--verbose=yes` is an error. |
| `1` | One value. `--port 8080`, `--port=8080`, and `-p8080`. A missing value is an error. |
| `+` | One or more values, in the following words: `-f a.txt b.txt`. The list stops at the next option or at a subcommand word of this level. Repeating the flag appends. The flag with no values is an error. |
| `*` | Zero or more values, collected the same way. The flag with no values stores an empty list. |

`--name=value` and an attached short value are the first value. For `+` and `*`, later words are still collected.

`-` is a value (stdin), not an option. It is accepted while a `+` or `*` list is open.

`--` ends option parsing for the list that is open. The words after it belong to that list, including words that start with `-`. `--` with no list open, and words left over, is an unexpected positional.

A bare word on a leaf is an unexpected positional. A bare word on a command that has children is an unknown command, unless it is one of those children.

Passing an arity-`1` option again overwrites the previous value.

### Defaults and required options

The default is used when the option is omitted.

- On a `?` type, a blank cell or `null` stores null. The option is not required.
- A non-optional type with a written default is not required. `8080` is the port when `--port` is absent.
- A blank cell on a non-optional number, bool, or `[]const u8` of arity `1` is required. Help prints `required`. Omitting it is an error.
- A quoted empty cell is blank after the CSV is read. A non-optional string therefore cannot default to `""`. Use `?[]const u8` and treat null as empty in the program.
- A flag defaults to `false` when the cell is blank. `false` and `true` are also accepted. `true` does not create an off switch: the flag stores `true` when it is present and `true` when that is already the default. Name the flag for the case that should turn on (`quiet`, `force`, `no-backup`) and leave the default `false`.

Required options are listed first in the usage line and first in the help table.

### Lists

For `+` and `*`, the default cell is a comma-separated list.

```csv
f,file,[]const u8,+,"a.txt, b.txt",Files to read
t,tag,u8,*,"1, 2",Tag numbers
```

Quote the cell so the commas stay inside it. Whitespace around an item is removed. Empty items are dropped. `a.txt, b.txt` is `a.txt` then `b.txt`.

`+` with no items is required. `*` with no items is an empty list when the type is not optional, and null when it is (`?[]const u8` and a blank or `null` cell).

Omitting a list uses that default. Passing `+` with no values is still an error and does not fall back to the default. Passing `*` with no values stores an empty list, even when the cell listed defaults. On an optional list, that empty list is distinct from null.

### Help text and quotes

`help` is the remainder of the line, so an unquoted description may contain commas.

Quote a field to put a comma inside `short`, `long`, `type`, `arity`, or `default`. A quote inside a quoted field is written twice: `"say ""hi"""` is `say "hi"`.

In help, `[]const u8` is shown as `text`. A flag has no value word. Arity `1` shows `<u16>` or `<text>`. `+` and `*` show `<text...>`.

## sub.csv

Comments in [`template/sub.csv`](template/sub.csv) repeat this section.

The columns are `long,path,help`. Blank lines and `#` lines are ignored. The first row that starts with `long,path,` is the header.

`long` is the word on the command line. It cannot start with `-`. The result tag uses the same `-` to `_` rule as option fields.

`path` is the child directory name. Blank means "use `long`". One segment only: no `/`, `\`, or NUL, not `.` or `..`, at most 255 bytes. The path from the schema root is at most 4096 bytes. A short mask keeps deep trees off operating-system path limits:

```csv
long,path,help
sync,s,Transfer with the remote
```

The user types `sync`. The files are `s/args.csv` and `s/sub.csv`.

`help` is the one line in the parent's Commands list. It is the rest of the row.

A file with only the header is a leaf. The result struct for that command has no `command` field. The file is still required. At most 64 rows. A duplicate word, field, or path is a compile error.

### The command value

A level with at least one child has `command: ?Union`. Each tag's payload is that child's struct.

```zig
if (args.command) |command| switch (command) {
    .serve => |serve| useServe(serve),
    .sync => |sync| useSync(sync),
} else {
    runParent(args);
}
```

Null means the word was omitted. The parent options are still parsed. Child options are not. There is no default command: a word that is absent is the parent, and a word that is present must name a row.

A child that itself has commands uses the same shape. In the demo, `remote.command` and `sync.command` are optional one level further down.

### Where the words go

`tool -v serve -p 9`:

1. `tool` is `argv[0]`.
2. `-v` is an option of the root `args.csv`, because it appears before the command word.
3. `serve` selects that row.
4. `-p 9` is parsed with `serve/args.csv`.

`tool serve -h` prints serve's help even when the root has a required option. The child is parsed before the parent's missing options are reported. `tool -h` prints the root help.

A `+` or `*` list does not swallow the command word. `-f a.txt serve` on the root stops the list at `serve` when `serve` is a child of that level.

## desc.txt

Optional plain text, one file per command. It is printed on that command's help after the usage lines and before the option table. It is not Markdown. Leading and trailing whitespace is trimmed. Blank lines inside the text stay.

A missing or empty file prints nothing. Child descriptions stay in the parent's `sub.csv`. They are not copied up from the child's `desc.txt`.

This is where a parent says what happens when `command` is null. The usage line only marks the word optional (`[command]`), and the Commands list only names the children.

## Help

`-h` and `--help` are recognized on every command unless that `args.csv` already defines `h` or `help`. Defining them makes them normal options under your type and default.

Help goes to stderr. For `-h` the process exits `0`. For any other usage error it prints the same page and exits `1`. `std.process.exit` does not run `defer`, so the `argv` list is not freed on that path. Out of memory does not print help and does not exit. `parse` returns `error.OutOfMemory`.

Inside `zig test`, nothing is printed and the process does not exit. The error is returned.

The page is:

1. `Usage`, the current command, then one line per child.
2. `desc.txt`, when it has text.
3. The option table. Required rows, a blank line, then the other rows. The default column is the compiled default, `none` for null or an empty optional list, or `required`.
4. `Commands`, when this level has any. The columns are the long name and the `sub.csv` help.

From the root of the demo schema the usage block looks like this:

```
Usage
  zig_clap [options] [command]
  zig_clap add -f <text...> -v <text> -p <u8> [options]
  zig_clap serve [options]
  zig_clap remote [options] [command]
```

`[options]` stands for the optional options, including built-in help. Required options are written out. `[command]` means the word may be omitted.

`printCommandHelp(program, level_dir)` prints one page without parsing. `level_dir` is the schema path the build uses internally: `args/` for the root, `args/serve/` for a child whose directory is `serve`, `args/s/push/` when those path cells were used. Most programs never call it. `parse` prints the page for the level that failed.

## Errors

| Error | When |
|---|---|
| `UnknownOption` | The option is not on this command |
| `UnknownCommand` | The word is not a child of this command |
| `MissingValue` | An option needs a value, or `+` was passed with none |
| `MissingArgument` | A required option was left off |
| `UnexpectedValue` | A flag was given `=value` |
| `UnexpectedPositional` | A bare word on a leaf, or words after `--` with no list open |
| `InvalidValue` | The value does not parse as the declared type |
| `Help` | `-h` or `--help` |
| `error.OutOfMemory` | Allocation failed. Returned to the caller |

A diagnostic line is written to the error log before the help page, except for `-h` and except under `zig test`.

## Memory

`deinit` frees the slices `parse` allocated: `+` and `*` values, and a default list that was copied because the option was omitted. String values that came from `argv` are not copied and must not be freed on their own. The iterator that produced `argv` has to stay alive until `deinit` returns.

Call `deinit` with the value `parse` returned. Do not pass a zero-initialized result.

## Limits

| Limit | Value |
|---|---|
| Options in one `args.csv` | 64 |
| Commands in one `sub.csv` | 64 |
| Nested commands | 64 |
| One path segment | 255 bytes |
| Schema path | 4096 bytes |
| One schema file | 1 MiB at configure time |

Hitting a schema limit is a compile error or a configure error, not a runtime parse error.

## Run the demo

The demo schema is [`src/args/`](src/args/). `src/main.zig` prints the parsed fields. From this repository:

```sh
zig build test
zig build run -- -h
zig build run --
zig build run -- -v serve -p 9
zig build run -- add -f a.txt b.txt -v 1 -p 3
zig build run -- remote
zig build run -- remote sync pull
zig build run -- remote --name upstream sync --force push -t -f a.txt
```

`zig build run --` with no further arguments runs the parent: `verbose` is false and `command` is null. `add` requires `--file`, `--version`, and `--patch`. `remote` with no further word keeps the default name `origin` and a null child command.

## What this parser does not do

These are outside the model on purpose.

- Positionals. A list of values belongs to a named `+` or `*` option. A bare word is a subcommand, or an error.
- A fixed set of string values, environment fallbacks, conflicts between options, aliases, and shell completion.
- An automatic off switch. A flag stores `true`. The default stays `false`, and the name is the case that turns on.
- Parent options after the command word. `tool serve -v` does not see a root `-v`.

## Repository layout

| Path | Role |
|---|---|
| [`template/`](template/) | Schema to copy. The CSV comments are the column reference |
| [`src/args/`](src/args/) | Demo schema used by `zig build run` |
| [`src/main.zig`](src/main.zig) | Demo program |
| [`src/mod.zig`](src/mod.zig) | Public module: `commandType`, `parse`, `deinit` |
| [`src/root.zig`](src/root.zig) | Parser. `zig build test` compiles this file directly |
| [`build.zig`](build.zig) | Reads `.args` and generates the schema module |

`src/mod.zig` also exports `ArgDef`, `Arity`, `Error`, `SubDef`, `max_command_depth`, `parseCsv`, `parseSubCsv`, `makeResultType`, `printHelp`, and `printCommandHelp`. A normal program uses `commandType`, `parse`, and `deinit`.
