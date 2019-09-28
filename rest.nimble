version = "1.0.3"
author = "disruptek"
description = "rest comfort"
license = "MIT"
requires "nim >= 0.20.0"
requires "foreach >= 1.0.0"

task test, "Runs the test suite":
  exec "nim c -r rest.nim"
