//! The parts of the trace replay harness that build outside turso_core.
//!
//! The replay itself (`mbt_tests/mod.rs`, `rows.rs`, `schema.rs`) uses
//! private turso_core APIs and test-only hooks, so it builds only as a module
//! of turso_core. `run-in-turso.sh` runs it there. This crate builds the ITF
//! reader from the same file and checks that every checked-in trace parses.

// The replay in turso_core uses the rest of the reader.
#[cfg(test)]
#[allow(dead_code)]
#[path = "../mbt_tests/itf.rs"]
mod itf;

#[cfg(test)]
mod tests {
    use super::itf::parse_trace;

    #[test]
    fn every_checked_in_trace_parses() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/mbt_tests/traces");
        let mut traces = 0;
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let text = std::fs::read_to_string(&path).unwrap();
            let steps = parse_trace(&text);
            assert!(!steps.is_empty(), "{} has no states", path.display());
            assert!(
                steps[0].action.eq_ignore_ascii_case("init"),
                "{} does not start with Init",
                path.display()
            );
            traces += 1;
        }
        assert_eq!(traces, 10);
    }
}
