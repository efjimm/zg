# zg

Personal fork of zg. Reduced memory usage, slightly better performance, slightly better binary
sizes, and less lines of code than upstream. Library is now just a single module instead of many.
This doesn't affect binary sizes - unicode data is only loaded if a function that uses it is
referenced. build.zig has been massively cut down and cleaned up.

I haven't upstreamed these changes because they're pretty extensive and opinionated, and I'm lazy.

Upstream: [https://codeberg.org/atman/zg](https://codeberg.org/atman/zg)

This library follows Zig master.
