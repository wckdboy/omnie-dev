// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
//! `jq` for Omnie Dev's WASI sandbox: jq's language through jaq's libraries, with jq's usual
//! flags. `jq [-r] [-c] [-n] [-s] [-j] [-e] [--tab] [--arg name value] [--argjson name json] FILTER [FILE...]`
use jaq_core::{compile::Compiler, load, Ctx, Native, RcIter};
use jaq_json::Val;
use std::io::{self, Read, Write};
use std::process::exit;

#[derive(Default)]
struct Opts { raw: bool, compact: bool, null_input: bool, slurp: bool, join: bool, exit_status: bool, tab: bool, sort: bool }

fn usage() -> ! {
    eprintln!("Usage: jq [-r] [-c] [-n] [-s] [-j] [-e] [-S] [--tab] [--arg name value] [--argjson name json] FILTER [FILE...]");
    exit(2)
}

fn main() {
    let mut opts = Opts::default();
    let mut vars: Vec<(String, Val)> = Vec::new();
    let mut positional = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "-r" | "--raw-output" => opts.raw = true,
            "-j" | "--join-output" => { opts.raw = true; opts.join = true }
            "-c" | "--compact-output" => opts.compact = true,
            "-n" | "--null-input" => opts.null_input = true,
            "-s" | "--slurp" => opts.slurp = true,
            "-e" | "--exit-status" => opts.exit_status = true,
            "-S" | "--sort-keys" => opts.sort = true,
            "--tab" => opts.tab = true,
            "--arg" => {
                let (Some(n), Some(v)) = (args.next(), args.next()) else { usage() };
                vars.push((n, Val::from(v)));
            }
            "--argjson" => {
                let (Some(n), Some(v)) = (args.next(), args.next()) else { usage() };
                match parse_all(v.as_bytes()).map(|mut v| v.pop()) {
                    Ok(Some(val)) => vars.push((n, val)),
                    _ => { eprintln!("jq: --argjson {n}: invalid JSON"); exit(2) }
                }
            }
            "-h" | "--help" => usage(),
            "--version" => { println!("jq-1.7 (jaq 2.3, Omnie Dev)"); return }
            s if s.starts_with('-') && s.len() > 2 && !s.starts_with("--") => {
                // Combined short flags: -rc
                for c in s[1..].chars() {
                    match c {
                        'r' => opts.raw = true, 'c' => opts.compact = true, 'n' => opts.null_input = true,
                        's' => opts.slurp = true, 'j' => { opts.raw = true; opts.join = true }
                        'e' => opts.exit_status = true, 'S' => opts.sort = true,
                        _ => usage(),
                    }
                }
            }
            _ => positional.push(a),
        }
    }
    let Some(code) = positional.first().cloned() else { usage() };
    let files = &positional[1..];

    // Compile.
    let names: Vec<String> = vars.iter().map(|(n, _)| format!("${n}")).collect();
    let arena = load::Arena::default();
    let loader = load::Loader::new(jaq_std::defs().chain(jaq_json::defs()));
    let modules = match loader.load(&arena, load::File { path: (), code: code.as_str() }) {
        Ok(m) => m,
        Err(errs) => { for (_, e) in errs { eprintln!("jq: error: {}", describe_load(&e)); } exit(3) }
    };
    let filter = match Compiler::<_, Native<Val>>::default()
        .with_funs(jaq_std::funs().chain(jaq_json::funs()))
        .with_global_vars(names.iter().map(|n| n.as_str()))
        .compile(modules)
    {
        Ok(f) => f,
        Err(errs) => {
            for (_, es) in errs { for (name, undefined) in es { eprintln!("jq: error: {name} is not defined ({undefined:?})"); } }
            exit(3)
        }
    };

    // Inputs.
    let mut inputs: Vec<Val> = Vec::new();
    if !opts.null_input || opts.slurp {
        let mut read = |bytes: &[u8], name: &str| match parse_all(bytes) {
            Ok(vals) => inputs.extend(vals),
            Err(e) => { eprintln!("jq: error (at {name}): {e}"); exit(2) }
        };
        if files.is_empty() {
            let mut buf = Vec::new();
            io::stdin().read_to_end(&mut buf).ok();
            read(&buf, "<stdin>");
        } else {
            for f in files {
                match std::fs::read(f) {
                    Ok(b) => read(&b, f),
                    Err(e) => { eprintln!("jq: error: Could not open {f}: {e}"); exit(2) }
                }
            }
        }
    }
    let runs: Vec<Val> = if opts.slurp {
        vec![Val::Arr(std::rc::Rc::new(std::mem::take(&mut inputs)))]
    } else if opts.null_input {
        vec![Val::Null]
    } else {
        std::mem::take(&mut inputs)
    };

    let empty = RcIter::new(Box::new(core::iter::empty()) as Box<dyn Iterator<Item = Result<Val, String>>>);
    let ctx = Ctx::new(vars.into_iter().map(|(_, v)| v), &empty);
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    let mut last: Option<bool> = None;
    let mut failed = false;
    for input in runs {
        for result in filter.run((ctx.clone(), input)) {
            match result {
                Ok(v) => {
                    last = Some(!matches!(v, Val::Null | Val::Bool(false)));
                    let text = match (&v, opts.raw) {
                        (Val::Str(s), true) => s.to_string(),
                        _ => { let mut s = String::new(); pretty(&mut s, &v, &opts, 0); s }
                    };
                    let _ = out.write_all(text.as_bytes());
                    if !opts.join { let _ = out.write_all(b"\n"); }
                }
                Err(e) => { let _ = out.flush(); eprintln!("jq: error: {e}"); failed = true; }
            }
        }
    }
    let _ = out.flush();
    if failed { exit(5) }
    if opts.exit_status { exit(match last { Some(true) => 0, Some(false) => 1, None => 4 }) }
}

/// Every JSON value in `bytes`, one after another (jq's input stream).
fn parse_all(bytes: &[u8]) -> Result<Vec<Val>, String> {
    use hifijson::token::Lex;
    let mut lexer = hifijson::SliceLexer::new(bytes);
    let mut vals = Vec::new();
    loop {
        match lexer.ws_token() {
            None => return Ok(vals),
            Some(token) => vals.push(Val::parse(token, &mut lexer).map_err(|e| e.to_string())?),
        }
    }
}

fn describe_load(e: &load::Error<&str>) -> String {
    match e {
        load::Error::Io(errs) => errs.iter().map(|(p, e)| format!("{p:?}: {e}")).collect::<Vec<_>>().join("; "),
        load::Error::Lex(errs) => errs.iter().map(|(exp, at)| format!("expected {} at {}", exp.as_str(), short(at))).collect::<Vec<_>>().join("; "),
        load::Error::Parse(errs) => errs.iter().map(|(exp, at)| format!("expected {} at {}", exp.as_str(), short(at))).collect::<Vec<_>>().join("; "),
    }
}

fn short(s: &str) -> String {
    let d: String = s.chars().take(24).collect();
    if s.chars().count() > 24 { format!("{d:?}…") } else { format!("{d:?}") }
}

/// jq's output format: two-space indents (or a tab), "key": value, or compact with -c.
fn pretty(out: &mut String, v: &Val, opts: &Opts, level: usize) {
    use core::fmt::Write;
    let indent = |out: &mut String, level: usize| {
        out.push('\n');
        for _ in 0..level { out.push_str(if opts.tab { "\t" } else { "  " }); }
    };
    match v {
        Val::Arr(items) if !items.is_empty() => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 { out.push(','); }
                if !opts.compact { indent(out, level + 1); }
                pretty(out, item, opts, level + 1);
            }
            if !opts.compact { indent(out, level); }
            out.push(']');
        }
        Val::Obj(map) if !map.is_empty() => {
            out.push('{');
            let mut entries: Vec<_> = map.iter().collect();
            if opts.sort { entries.sort_by(|a, b| a.0.cmp(b.0)); }
            for (i, (k, item)) in entries.into_iter().enumerate() {
                if i > 0 { out.push(','); }
                if !opts.compact { indent(out, level + 1); }
                let _ = write!(out, "{}", Val::Str(k.clone()));
                out.push_str(if opts.compact { ":" } else { ": " });
                pretty(out, item, opts, level + 1);
            }
            if !opts.compact { indent(out, level); }
            out.push('}');
        }
        // jq prints whole numbers without a decimal point, whatever their representation.
        Val::Float(f) if f.is_finite() && f.fract() == 0.0 && f.abs() < 1e17 => { let _ = write!(out, "{f:.0}"); }
        other => { let _ = write!(out, "{other}"); }
    }
}
