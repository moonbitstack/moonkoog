name = "moonbitstack/moonkoog-integration"

version = "0.0.1"

// The peer programs that drive this library from another process. They are not published:
// `.moonignore` keeps this directory out of the package, and the workspace members below are
// what let them build against the working tree instead of a release.
import {
  "moonbitstack/moonkoog@0.6.1",
  "moonbitstack/moonmcp@0.1.12",
  "moonbitstack/moonmuse@0.1.1",
  "moonbitstack/moonstate@0.1.1",
  "moonbitstack/moona2a@0.1.1",
  "moonbitstack/moonacp@0.1.1",
  "moonbitstack/mooncat@0.19.8",
  "moonbitstack/moondb@0.2.8",
  "moonbitstack/moonpostgres@0.7.0",
  "moonbitlang/async@0.22.5",
}

source = "src"
