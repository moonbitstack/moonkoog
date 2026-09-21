// File tools (Koog agents-ext `ai.koog.agents.ext.tool.file`): the read / write / list tools
// an agent uses to work with files. They operate through a `FileSystem` seam (Koog's
// `FileSystemProvider`), so the same tools run against a real filesystem or the in-memory one
// tests use — the faithful, testable equivalent of Koog wiring them to a provider.

///|
/// The filesystem a file tool reads and writes through (Koog `FileSystemProvider`).
pub(open) trait FileSystem {
  fn read(Self, path : String) -> String?
  fn write(Self, path : String, content : String) -> Unit
  fn list(Self, path : String) -> Array[String]
}

///|
/// An in-memory filesystem: a map of path to contents; `list` returns the paths under a
/// directory prefix.
pub struct MemFileSystem {
  files : Map[String, String]
}

///|
/// An empty in-memory filesystem.
pub fn MemFileSystem::new() -> MemFileSystem {
  { files: Map([]), }
}

///|
pub impl FileSystem for MemFileSystem with fn read(self, path) {
  self.files.get(path)
}

///|
pub impl FileSystem for MemFileSystem with fn write(self, path, content) {
  self.files[path] = content
}

///|
pub impl FileSystem for MemFileSystem with fn list(self, path) {
  let prefix = if path.has_suffix("/") { path } else { path + "/" }
  let out : Array[String] = []
  for name, _ in self.files {
    if name.has_prefix(prefix) {
      out.push(name)
    }
  }
  out.sort()
  out
}

///|
/// Read a file's contents (Koog `ReadFileTool`).
pub struct ReadFileTool {
  fs : &FileSystem
}

///|
/// A read-file tool over `fs`.
pub fn ReadFileTool::new(fs : &FileSystem) -> ReadFileTool {
  { fs, }
}

///|
pub impl Tool for ReadFileTool with fn descriptor(_self) {
  {
    name: "read_file",
    description: "Read the contents of a file at a path.",
    required_parameters: [
      { name: "path", description: "the file path", ptype: TString, },
    ],
    optional_parameters: [],
  }
}

///|
pub impl Tool for ReadFileTool with fn execute_raw(self, args) {
  let path = arg_string(args, "path")
  match self.fs.read(path) {
    Some(content) => content
    None => "file not found: " + path
  }
}

///|
/// Write contents to a file (Koog `WriteFileTool`).
pub struct WriteFileTool {
  fs : &FileSystem
}

///|
/// A write-file tool over `fs`.
pub fn WriteFileTool::new(fs : &FileSystem) -> WriteFileTool {
  { fs, }
}

///|
pub impl Tool for WriteFileTool with fn descriptor(_self) {
  {
    name: "write_file",
    description: "Write text contents to a file at a path.",
    required_parameters: [
      { name: "path", description: "the file path", ptype: TString, },
      { name: "content", description: "the text to write", ptype: TString, },
    ],
    optional_parameters: [],
  }
}

///|
pub impl Tool for WriteFileTool with fn execute_raw(self, args) {
  let path = arg_string(args, "path")
  self.fs.write(path, arg_string(args, "content"))
  "Wrote " + path
}

///|
/// List the files under a directory (Koog `ListDirectoryTool`).
pub struct ListDirectoryTool {
  fs : &FileSystem
}

///|
/// A list-directory tool over `fs`.
pub fn ListDirectoryTool::new(fs : &FileSystem) -> ListDirectoryTool {
  { fs, }
}

///|
pub impl Tool for ListDirectoryTool with fn descriptor(_self) {
  {
    name: "list_directory",
    description: "List the files under a directory path.",
    required_parameters: [
      { name: "path", description: "the directory path", ptype: TString, },
    ],
    optional_parameters: [],
  }
}

///|
pub impl Tool for ListDirectoryTool with fn execute_raw(self, args) {
  let entries = self.fs.list(arg_string(args, "path"))
  entries.join("\n")
}

///|
pub extend ListDirectoryTool with Tool::{descriptor, execute_raw}

///|
pub extend MemFileSystem with FileSystem::{read, list, write}

///|
pub extend ReadFileTool with Tool::{descriptor, execute_raw}

///|
pub extend WriteFileTool with Tool::{descriptor, execute_raw}
