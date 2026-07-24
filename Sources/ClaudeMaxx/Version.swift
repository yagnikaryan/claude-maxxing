/// Identity of the running build, so a report from someone else's machine is
/// traceable. Bumped by hand alongside a git tag.
///
/// Deliberately just a constant. SwiftPM has no supported way to bake git
/// state into a plain `executableTarget` without a codegen step, and a daemon
/// that shelled out to `git` at startup would be reporting the *clone's*
/// current state, not the state the running binary was built from — which is
/// exactly the stale-binary confusion `doctor.sh` exists to catch. `doctor.sh`
/// runs in the clone and pairs this with `git describe`, so the two together
/// say both what is running and what the source is at.
enum Version {
    static let current = "0.1.0"
}
