# Globe

Explore the Earth on a 3D globe: spin it, zoom in to countries and see
their names and borders. An app for [Dazzle](https://github.com/dazzleos/dazzle).

Install it on Dazzle from Settings, Software.

## Building

Globe is built with Dazzle's modules (kete_vc4 and the rest) and tools,
through Dazzle's `addApp` (see its `build.zig`): a commit of Dazzle's, as
`build.zig.zon` pins it. Zig is the version Dazzle's `scripts/zig` fetches:

    git clone https://github.com/dazzleos/dazzle ../dazzle
    ../dazzle/scripts/zig build test    # the tests, on this computer
    ../dazzle/scripts/zig build         # the program, and zig-out/apps

With changes of your own to Dazzle, build with that checkout instead:
`--fork=../dazzle`. To move Globe on to a newer Dazzle, pin its commit:

    git -C ../dazzle archive --format=tar.gz -o /tmp/dazzle.tar.gz <commit>
    zig fetch /tmp/dazzle.tar.gz        # prints the hash for build.zig.zon

(the archive has only the commit's files, so this is quick, and its hash
is the one fetching the commit from GitHub gives).

The countries are [Natural Earth](https://www.naturalearthdata.com)'s
Admin-0 Countries (in the public domain), at 1:110m and 1:50m
(`src/data`), made into triangles at build time by `tools/mkmap.zig`.

`zig-out/apps` has Globe's archive, icon, screenshot and catalogue
(`apps.json`), signed with `-Dsigning-key` or `DAZZLE_SIGNING_KEY`. Each
push to the default branch publishes them as the "latest" release, one of
the sources Dazzle's catalogue lists.

To try a build on a Pi before publishing it, serve it with Dazzle's
(Settings, Software, Software server):

    cd ../dazzle && zig build serve -- --source=globe=../globe/zig-out
