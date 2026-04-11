Agent 1:
flake.nix should have ngspice, xyce, vacask installed and available for testing and benchmarking. - HOWEVER, it should be optional to install them so if someone uses the flake.nix for using the executable then it doesn't have to install it for them.

Agent 2:
All benches & tests shouldn't be crates. - if you will make crates make it use the output from the build.rs (the executable produced of the app) to test it against ngspice, xyce, VACASK testset in tests/ or benches/ not in crates/

Extend Agent 2:
Extend the benches/testset to be AGAINST them all, not just ngspice so we can make this THE BEST OF ALL OF THEM...

Agent 3: (Not in parallel like the above, have to wait)
Each crate should have the only functions it exposes defined in lib.rs, everything else is wrapped there for usage. - Allows for abstraction if there's different solving, compute, etc... methods. - ALlows for each crate to crate interactions because the API is stable, not internally based.

### After all the above.

Agent 4: (Run alone)
We need to run code quality reviewers on ALL the repos to make sure they are written well, performant, uses my utility/ data-oriented structures, and is data-oriented in general. No useless code, or useless workarounds, or unnnecssary logic. Straight to the point. No fluff. No bloat. No warnings, no errors.

Agent 5: (Run alone)
Afterwards, we need to finally benchmark it against all other repos and come up with concrete numbers.

Agent 6:
use flamegraph and profiling tools to speed up my code, making it factors faster than my competitors. Think well if there's a simpler logic system that produces less assembly that could make my code run faster. Make sure non of my logic is made for "small circuits" it should work for all sizes.
Profile it after, and update the results.

Agent 7: Clean up the docs, create ci/cd pipelines to run tests, benchmarks, and code quality checks on every commit. Make sure the documentation is clear, simple, concise, and helpful. Create a small website for the documentation so it is easy to see, the website is essentially a markdown renderer with a search bar and a NICE NICE UI (use my skills for this).
