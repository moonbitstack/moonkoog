// The regex search tool (Koog agents-ext `RegexSearchTool`): search the files under a
// directory for a regular-expression pattern and report the ones that match. The pattern is
// compiled with the standard library's `@string.Regex`, so this is real regular-expression
// matching, not a substring approximation.

///|
/// Search the files under a path for `pattern`, listing those whose contents match (Koog
/// `RegexSearchTool`).
pub struct RegexSearchTool {
  fs : &FileSystem
}

///|
/// A regex-search tool over `fs`.
pub fn RegexSearchTool::new(fs : &FileSystem) -> RegexSearchTool {
  { fs, }
}

///|
pub impl Tool for RegexSearchTool with fn descriptor(_self) {
  {
    name: "search_files",
    description: "Search the files under a directory for a regular-expression pattern.",
    required_parameters: [
      { name: "path", description: "the directory to search", ptype: TString, },
      {
        name: "pattern",
        description: "the regular expression",
        ptype: TString,
      },
    ],
    optional_parameters: [],
  }
}

///|
pub impl Tool for RegexSearchTool with fn execute_raw(self, args) {
  let regex = @string.Regex::Regex(arg_string(args, "pattern"))
  let out = StringBuilder()
  for file in self.fs.list(arg_string(args, "path")) {
    if self.fs.read(file) is Some(content) && regex.execute(content) is Some(_) {
      out.write_string(file + "\n")
    }
  }
  out.to_string()
}

///|
pub extend RegexSearchTool with Tool::{descriptor, execute_raw}
