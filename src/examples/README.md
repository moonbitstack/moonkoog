# Examples

Each directory is a package that runs on its own:

```bash
moon run src/examples/01-quickstart
```

They use a scripted provider, so none of them needs a key or a network.

`07-annotated-tools` keeps its tools in `tools.mbt` as `#koog.tool` functions; `tools.g.mbt` is what `cmd/tool` writes from them.
