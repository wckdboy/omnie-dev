// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
//! Exercises RunKit's WASI layer: `wasi-probe <command> [args]`.
use std::io::{Read, Write};
use std::{env, fs, process};

fn main() {
    let args: Vec<String> = env::args().collect();
    let cmd = args.get(1).map(String::as_str).unwrap_or("");
    match cmd {
        "echo" => println!("{}", args[2..].join(" ")),
        "env" => println!("{}", env::var(&args[2]).unwrap_or_else(|_| "<unset>".into())),
        "stdin" => {
            let mut s = String::new();
            std::io::stdin().read_to_string(&mut s).unwrap();
            print!("{}", s.to_uppercase());
        }
        "ls" => {
            let mut names: Vec<String> = fs::read_dir(&args[2]).unwrap().map(|e| {
                let e = e.unwrap();
                let kind = if e.file_type().unwrap().is_dir() { "/" } else { "" };
                format!("{}{}", e.file_name().to_string_lossy(), kind)
            }).collect();
            names.sort();
            println!("{}", names.join(" "));
        }
        "cat" => match fs::read_to_string(&args[2]) {
            Ok(s) => print!("{}", s),
            Err(e) => { eprintln!("cat: {}: {}", args[2], e); process::exit(1) }
        },
        "write" => fs::write(&args[2], &args[3]).unwrap(),
        "append" => {
            let mut f = fs::OpenOptions::new().append(true).create(true).open(&args[2]).unwrap();
            f.write_all(args[3].as_bytes()).unwrap();
        }
        "mv" => fs::rename(&args[2], &args[3]).unwrap(),
        "rm" => fs::remove_file(&args[2]).unwrap(),
        "mkdir" => fs::create_dir_all(&args[2]).unwrap(),
        "size" => println!("{}", fs::metadata(&args[2]).unwrap().len()),
        "time" => {
            let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
            println!("{}", if t > 1_700_000_000 { "ok" } else { "bad" });
        }
        "exit" => process::exit(args[2].parse().unwrap()),
        "spin" => loop { std::hint::black_box(0); },
        "alloc" => {
            let mb: usize = args[2].parse().unwrap();
            let v = vec![1u8; mb << 20];
            println!("{}", v.iter().map(|&b| b as usize).sum::<usize>() >> 20);
        }
        _ => { eprintln!("unknown command {:?}", cmd); process::exit(2) }
    }
}
