#!/bin/bash -xue

which opam > /dev/null || { echo 'opam not found!'; exit 1; }
{ opam remote list | grep Incubaid/opam-repository-devel > /dev/null; } || { opam remote add incubaid-devel -k git git://github.com/Incubaid/opam-repository-devel.git; }

opam switch 4.01.0
eval `opam config env`

opam remove -y camltc
opam update -y
opam install -y conf-libev
opam install -y camlbz2
opam install -y lwt.2.4.4
opam install -y camltc.0.9.2
opam install -y bisect
