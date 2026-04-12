Note: use scripts/run_benchmark.sh, validate the behavior of our SPICE IS IDENTICAL to other spice software, but immensely faster.

Agent 1: (Not in parallel like the above, have to wait)
Each crate should have the only functions it exposes defined in lib.rs, everything else is wrapped there for usage. - Allows for abstraction if there's different solving, compute, etc... methods. - ALlows for each crate to crate interactions because the API is stable, not internally based.

Agent 2: (Run alone)
We need to run code quality reviewers on ALL the repos to make sure they are written well, performant, uses my utility/ data-oriented structures, and is data-oriented in general. No useless code, or useless workarounds, or unnnecssary logic. Straight to the point. No fluff. No bloat. No warnings, no errors.

Agent 3: (Run alone)
Afterwards, we need to finally benchmark it against all other repos and come up with concrete numbers.

Agent 4:
use flamegraph and profiling tools to speed up my code, making it factors faster than my competitors. Think well if there's a simpler logic system that produces less assembly that could make my code run faster. Make sure non of my logic is made for "small circuits" it should work for all sizes.
Profile it after, and update the results.

Agent 5: Clean up the docs, create ci/cd pipelines to run tests, benchmarks, and code quality checks on every commit. Make sure the documentation is clear, simple, concise, and helpful. Create a small website for the documentation so it is easy to see, the website is essentially a markdown renderer with a search bar and a NICE NICE UI (use my skills for this).
