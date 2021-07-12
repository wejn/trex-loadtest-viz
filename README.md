# TRex Loadtest Visualizer
Simple visualizer (using [C3.js](https://c3js.org/)) for Pim's TRex loadtester.

## What's this?
A script (`graph.rb`) to graph output from Pim's TRX loadtester.

## Install / run

Install:

``` sh
C3=c3-0.7.20.tar.gz
C3D=c3-0.7.20
if test ! -d $C3D; then
  wget https://github.com/c3js/c3/archive/refs/tags/v0.7.20.tar.gz -O $C3
  tar axvf $C3
fi
test -f c3.css || ln -s c3-0.7.20/c3.css .
test -f c3.min.js || ln -s c3-0.7.20/c3.min.js .
test -f d3.v5.min.js || ln -s c3-0.7.20/docs/js/d3-5.8.2.min.js d3.v5.min.js
```

Run:

``` sh
ruby graph.rb *.json
```

That will spit out `ltdata.js` as well as `index.html`. The rest needed
files should be in the repo.

## Credits
© 2021 Michal Jirků, licensed under GPL-3.0 [unless agreed otherwise]

The `c3-0.7.20`, `jquery.min.js` are covered by their respective licenses.
