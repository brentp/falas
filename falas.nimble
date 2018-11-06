import ospaths
template thisModuleFile: string = instantiationInfo(fullPaths = true).filename

when fileExists(thisModuleFile.parentDir / "falas/falas.nim"):
  # In the git repository the Nimble sources are in a ``src`` directory.
  import src/falaspkg/version as _
else:
  # When the package is installed, the ``src`` directory disappears.
  import falaspkg/version as _

# Package

version       = falasVersion
author        = "Brent Pedersen"
description   = "fragment-aware local assembler for short reads"
license       = "MIT"


# Dependencies

srcDir = "src"
installExt = @["nim"]
bin = @["falas"]

skipDirs = @["tests"]

import ospaths,strutils

task test, "run the tests":
  exec "nim c --lineDir:on --debuginfo -r --threads:on tests/all"

task docs, "Builds documentation":
  mkDir("docs"/"falas")
  for file in listfiles("src/"):
    if file.endswith("value.nim"): continue
    if splitfile(file).ext == ".nim":
      exec "nim doc2 --verbosity:0 --hints:off -o:" & "docs" /../ file.changefileext("html").split("/", 1)[1] & " " & file

