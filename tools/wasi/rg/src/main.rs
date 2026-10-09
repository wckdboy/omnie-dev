// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
//! `rg` for Omnie Dev's WASI sandbox: ripgrep's searcher, printer and .gitignore-aware walker,
//! single-threaded, with ripgrep's common flags and its non-terminal output (`path:line:text`).
//! `rg [-i|-S] [-F] [-w] [-v] [-o] [-l] [-c] [-n|-N] [-A n] [-B n] [-C n] [-m n] [-g GLOB]... [-t TYPE]...
//!     [--hidden] [--no-ignore] [-uu] PATTERN [PATH...]`
use grep::printer::{StandardBuilder, SummaryBuilder, SummaryKind};
use grep::regex::RegexMatcherBuilder;
use grep::searcher::{BinaryDetection, SearcherBuilder};
use ignore::overrides::OverrideBuilder;
use ignore::types::TypesBuilder;
use ignore::WalkBuilder;
use std::process::exit;
use termcolor::NoColor;

#[derive(Default)]
struct Opts {
    ignore_case: bool, smart_case: bool, fixed: bool, word: bool, invert: bool,
    files_with_matches: bool, count: bool, no_line_number: bool, only_matching: bool,
    after: usize, before: usize, max_count: Option<u64>,
    globs: Vec<String>, types: Vec<String>, hidden: bool, no_ignore: bool, files: bool,
}

fn usage() -> ! {
    eprintln!("Usage: rg [-i|-S] [-F] [-w] [-v] [-o] [-l] [-c] [-n|-N] [-A n] [-B n] [-C n] [-m n] [-g GLOB] [-t TYPE] [--hidden] [--no-ignore] [--files] PATTERN [PATH...]");
    exit(2)
}

fn number(v: Option<String>) -> usize { v.and_then(|v| v.parse().ok()).unwrap_or_else(|| usage()) }

fn main() {
    let mut o = Opts::default();
    let mut positional: Vec<String> = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        // -A3 and --context=3 as well as -A 3.
        let (flag, inline) = match a.split_once('=') {
            Some((f, v)) if a.starts_with("--") => (f.to_string(), Some(v.to_string())),
            _ if a.len() > 2 && a.starts_with('-') && !a.starts_with("--") && "ABCmgt".contains(&a[1..2]) => (a[..2].to_string(), Some(a[2..].to_string())),
            _ => (a.clone(), None),
        };
        let mut value = || inline.clone().or_else(|| args.next());
        match flag.as_str() {
            "-i" | "--ignore-case" => o.ignore_case = true,
            "-S" | "--smart-case" => o.smart_case = true,
            "-F" | "--fixed-strings" => o.fixed = true,
            "-w" | "--word-regexp" => o.word = true,
            "-v" | "--invert-match" => o.invert = true,
            "-l" | "--files-with-matches" => o.files_with_matches = true,
            "-c" | "--count" => o.count = true,
            "-o" | "--only-matching" => o.only_matching = true,
            "-n" | "--line-number" => o.no_line_number = false,
            "-N" | "--no-line-number" => o.no_line_number = true,
            "-A" | "--after-context" => o.after = number(value()),
            "-B" | "--before-context" => o.before = number(value()),
            "-C" | "--context" => { let n = number(value()); o.after = n; o.before = n }
            "-m" | "--max-count" => o.max_count = Some(number(value()) as u64),
            "-g" | "--glob" => o.globs.push(value().unwrap_or_else(|| usage())),
            "-t" | "--type" => o.types.push(value().unwrap_or_else(|| usage())),
            "--hidden" | "-." => o.hidden = true,
            "--no-ignore" => o.no_ignore = true,
            "-u" => o.no_ignore = true,
            "-uu" => { o.no_ignore = true; o.hidden = true }
            "--files" => o.files = true,
            "-h" | "--help" => usage(),
            "--" => { positional.extend(args.by_ref()); }
            s if s.starts_with('-') && s.len() > 1 => { eprintln!("rg: unknown flag {s}"); usage() }
            _ => positional.push(a),
        }
    }
    let pattern = if o.files { None } else if positional.is_empty() { usage() } else { Some(positional.remove(0)) };
    // Piped text (Omnie's shell says so) is searched when no path is given, as ripgrep does.
    let piped = positional.is_empty() && std::env::var_os("OMNIE_STDIN_PIPED").is_some();
    let paths = if positional.is_empty() { vec![".".to_string()] } else { positional };

    let mut walk = WalkBuilder::new(&paths[0]);
    for p in &paths[1..] { walk.add(p); }
    walk.threads(1).hidden(!o.hidden).sort_by_file_name(|a, b| a.cmp(b));
    if o.no_ignore { walk.git_ignore(false).git_global(false).git_exclude(false).ignore(false).parents(false); }
    // A project folder without .git still has its .gitignore honored, as people expect here.
    walk.require_git(false);
    if !o.globs.is_empty() {
        let mut ob = OverrideBuilder::new(".");
        for g in &o.globs { if let Err(e) = ob.add(g) { eprintln!("rg: {e}"); exit(2) } }
        walk.overrides(ob.build().unwrap_or_else(|e| { eprintln!("rg: {e}"); exit(2) }));
    }
    if !o.types.is_empty() {
        let mut tb = TypesBuilder::new();
        tb.add_defaults();
        for t in &o.types { tb.select(t); }
        walk.types(tb.build().unwrap_or_else(|e| { eprintln!("rg: {e}"); exit(2) }));
    }

    let display = |p: &std::path::Path| -> String {
        let s = p.to_string_lossy();
        s.strip_prefix("./").map(str::to_string).unwrap_or_else(|| s.into_owned())
    };

    if o.files {
        let mut any = false;
        for entry in walk.build().flatten() {
            if entry.file_type().map_or(false, |t| t.is_file()) { println!("{}", display(entry.path())); any = true }
        }
        exit(if any { 0 } else { 1 })
    }

    let pattern = pattern.unwrap();
    let case_insensitive = o.ignore_case || (o.smart_case && !pattern.chars().any(char::is_uppercase));
    let matcher = RegexMatcherBuilder::new()
        .case_insensitive(case_insensitive)
        .fixed_strings(o.fixed)
        .word(o.word)
        .line_terminator(Some(b'\n'))
        .build(&pattern)
        .unwrap_or_else(|e| { eprintln!("rg: {e}"); exit(2) });
    let mut searcher = SearcherBuilder::new()
        .binary_detection(BinaryDetection::quit(b'\x00'))
        .line_number(!o.no_line_number)
        .invert_match(o.invert)
        .after_context(o.after)
        .before_context(o.before)
        .build();

    let stdout = std::io::stdout();
    // One file named on its own prints without its name, as ripgrep does.
    let with_name = !(paths.len() == 1 && std::path::Path::new(&paths[0]).is_file());
    let mut standard = StandardBuilder::new().path(with_name).max_matches(o.max_count).only_matching(o.only_matching).build(NoColor::new(stdout.lock()));
    let kind = if o.files_with_matches { SummaryKind::PathWithMatch } else { SummaryKind::Count };
    let mut summary = SummaryBuilder::new().kind(kind).path(with_name || o.files_with_matches).max_matches(o.max_count).build(NoColor::new(std::io::stdout()));

    let mut matched = false;
    let mut errors = false;
    if piped && !o.files {
        let stdin = std::io::stdin();
        let result = if o.files_with_matches || o.count {
            // A count of piped text is just the number, as ripgrep prints it.
            let mut sink = if o.count { summary.sink(&matcher) } else { summary.sink_with_path(&matcher, "<stdin>") };
            let r = searcher.search_reader(&matcher, stdin.lock(), &mut sink);
            matched = sink.has_match();
            r
        } else {
            let mut sink = standard.sink(&matcher);
            let r = searcher.search_reader(&matcher, stdin.lock(), &mut sink);
            matched = sink.has_match();
            r
        };
        if let Err(e) = result { eprintln!("rg: <stdin>: {e}"); exit(2) }
        exit(if matched { 0 } else { 1 })
    }
    for entry in walk.build() {
        let entry = match entry { Ok(e) => e, Err(e) => { eprintln!("rg: {e}"); errors = true; continue } };
        if !entry.file_type().map_or(false, |t| t.is_file()) { continue }
        let shown = display(entry.path());
        let result = if o.files_with_matches || o.count {
            let mut sink = summary.sink_with_path(&matcher, &shown);
            let r = searcher.search_path(&matcher, entry.path(), &mut sink);
            matched |= sink.has_match();
            r
        } else {
            let mut sink = standard.sink_with_path(&matcher, &shown);
            let r = searcher.search_path(&matcher, entry.path(), &mut sink);
            matched |= sink.has_match();
            r
        };
        if let Err(e) = result { eprintln!("rg: {shown}: {e}"); errors = true }
    }
    exit(if errors && !matched { 2 } else if matched { 0 } else { 1 })
}
