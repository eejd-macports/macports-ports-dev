# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:ft=tcl:et:sw=4:ts=4:sts=4
#
# Internal helpers shared by the rust-1.0 and cargo_fetch-1.0 PortGroups.
#
# This file is not a PortGroup and must not be included with `PortGroup`.
# Both PortGroups source it by path, so the procedures below are available
# whichever of the two a Portfile uses:
#
#     source [file join [file dirname [info script]] rust_cache-1.0.tcl]
#
# Everything here is deliberately free of Portfile options and side effects on
# the port's state: the procedures take their inputs as arguments and either
# return a value or touch only the paths they are handed. That keeps them
# testable without a port context (see tests/rustcache-1.0.tcl) and keeps the
# policy decisions -- which crates are shared, what the remap is -- in the
# PortGroups where they can be overridden.

namespace eval rust {}

# Render cargo's config.toml.
#
# Pure: returns the file's text and touches nothing. `spec` is a dict; every
# key is optional, and a section is emitted only when its key is present, so
# one procedure covers both the source half written after extraction and the
# build half written for every non-toolchain port.
#
#   paths     list of directories for cargo's `paths` overrides. Emitted
#             first, because TOML top-level keys must precede every table.
#   sources   dict:
#               directory        path of the directory source that replaces
#                                crates.io (required when `sources` is given)
#               local_directory  path of a second directory source, named
#                                "macports-local", for crates that cannot be
#                                shared between ports (optional)
#               git              list of {url branch replacement} triples
#                                redirecting a git dependency at `url` to the
#                                named directory source
#   build     dict:
#               rustc      path to the rustc to use (optional)
#               rustflags  list of flags (optional)
#   targets   list of {triplet linker} pairs
#
proc rust::render_cargo_config {spec} {
    set lines [list]

    if {[dict exists $spec paths] && [llength [dict get $spec paths]] > 0} {
        set quoted [list]
        foreach path [dict get $spec paths] {
            lappend quoted "\"${path}\""
        }
        lappend lines "paths = \[[join $quoted {, }]\]"
    }

    if {[dict exists $spec sources]} {
        set sources [dict get $spec sources]

        # Avoid downloading files from the network during the build phase by
        # replacing crates.io with a local directory source.
        # https://doc.rust-lang.org/cargo/reference/source-replacement.html
        lappend lines "\[source\]"
        lappend lines "\[source.macports\]"
        lappend lines "directory = \"[dict get $sources directory]\""
        if {[dict exists $sources local_directory] && [dict get $sources local_directory] ne ""} {
            lappend lines "\[source.macports-local\]"
            lappend lines "directory = \"[dict get $sources local_directory]\""
        }
        lappend lines "\[source.crates-io\]"
        lappend lines "replace-with = \"macports\""
        # Poison the registry cargo would otherwise fall back to.
        lappend lines "local-registry = \"/var/empty\""
        if {[dict exists $sources git]} {
            foreach entry [dict get $sources git] {
                lassign $entry url branch replacement
                if {$replacement eq ""} {
                    set replacement macports
                }
                lappend lines "\[source.\"${url}\"\]"
                lappend lines "git = \"${url}\""
                lappend lines "branch = \"${branch}\""
                lappend lines "replace-with = \"${replacement}\""
            }
        }
    }

    if {[dict exists $spec build]} {
        set build [dict get $spec build]
        lappend lines "\[build\]"
        if {[dict exists $build rustc] && [dict get $build rustc] ne ""} {
            lappend lines "rustc = \"[dict get $build rustc]\""
        }
        if {[dict exists $build rustflags] && [dict get $build rustflags] ne ""} {
            lappend lines "rustflags = \[\"[join [dict get $build rustflags] {", "}]\"\]"
        }
    }

    if {[dict exists $spec targets]} {
        foreach entry [dict get $spec targets] {
            lassign $entry triplet linker
            lappend lines "\[target.${triplet}\]"
            lappend lines "linker = \"${linker}\""
        }
    }

    if {[llength $lines] == 0} {
        return ""
    }
    return "[join $lines \n]\n"
}

# Summarise the contents of an extracted crate directory as a two-element
# list {number-of-files newest-mtime}.
#
# This is how a crate a port has modified in place -- a reinplace from
# rust::old_macos_compatibility, or a patch applied by the Portfile -- is told
# apart from a pristine one, without hashing every file of every crate. The
# signature is taken right after extraction and compared before the shared
# vendor tree is assembled: a crate whose signature still matches is byte-for-
# byte what the .crate contained and can be shared with other ports, and one
# whose signature moved must stay private to this port.
#
# .cargo-checksum.json is excluded because the PortGroup writes it itself
# after extraction, so it would move every crate's signature.
proc rust::vendor_signature {dir} {
    set count 0
    set newest 0
    if {![file isdirectory $dir]} {
        return [list 0 0]
    }
    foreach path [rust::_walk_files $dir] {
        if {[file tail $path] eq ".cargo-checksum.json"} {
            continue
        }
        incr count
        set mtime [file mtime $path]
        if {$mtime > $newest} {
            set newest $mtime
        }
    }
    return [list $count $newest]
}

# Every regular file below `dir`, recursively. Symlinks are counted as files
# and never followed, so a link loop cannot hang the walk.
proc rust::_walk_files {dir} {
    set files [list]
    set pending [list $dir]
    while {[llength $pending] > 0} {
        set current [lindex $pending end]
        set pending [lrange $pending 0 end-1]
        foreach entry [glob -nocomplain -directory $current -types {f l} -- * .*] {
            if {[file tail $entry] in {. ..}} {
                continue
            }
            lappend files $entry
        }
        foreach entry [glob -nocomplain -directory $current -types d -- * .*] {
            if {[file tail $entry] in {. ..}} {
                continue
            }
            if {[file type $entry] eq "link"} {
                continue
            }
            lappend pending $entry
        }
    }
    return $files
}

# The remap that makes a port's rustc command line independent of where the
# port happens to be built.
#
# sccache hashes the whole rustc argv apart from a short list of ignored flags
# (-L, --extern, --out-dir, --check-cfg, --diagnostic-width), so
# --remap-path-prefix is itself hashed: two ports remapping their own private
# work directories to the empty string still produce two different command
# lines and therefore two different cache keys. Mapping the shared *parents* --
# the build root and the shared vendor tree -- onto fixed tokens instead gives
# every port the same arguments, and rustc applies the last matching rule, so
# the more specific vendor rule is listed second.
#
# The tokens also make the emitted debug paths node-independent, which matters
# for a binary archive built on one machine and installed on another.
proc rust::default_remap {build_root vendor_dir} {
    set remap [list]
    if {$build_root ne ""} {
        lappend remap $build_root /macports/build
    }
    if {$vendor_dir ne ""} {
        lappend remap $vendor_dir /macports/vendor
    }
    return $remap
}

# Publish a content-addressed copy of the linker wrapper and return its path.
#
# cargo passes `-C linker=<path>` on every rustc invocation, and MacPorts'
# linker is a per-port wrapper script under ${workpath}/compwrap, so the flag
# alone is enough to give every port a distinct cache key. Copying the wrapper
# to a path named after its own contents makes ports that would run the same
# linker share one path, and keeps ports whose wrapper genuinely differs apart.
#
# The copy is staged under a unique name and renamed into place, so two ports
# publishing the same wrapper concurrently cannot observe a partial file.
proc rust::shared_linker {cache_dir wrapper} {
    if {![file exists $wrapper]} {
        return $wrapper
    }
    set digest [sha256 file $wrapper]
    set target_dir [file join $cache_dir compwrap $digest]
    set target [file join $target_dir [file tail $wrapper]]
    if {[file exists $target]} {
        return $target
    }
    file mkdir $target_dir
    set staging [file join $target_dir ".tmp-[pid]-[clock clicks]"]
    file copy -force -- $wrapper $staging
    file attributes $staging -permissions 0755
    if {[catch {file rename -- $staging $target}]} {
        # Another port won the race; its copy has the same contents as ours.
        file delete -force -- $staging
    }
    if {[file exists $target]} {
        return $target
    }
    return $wrapper
}
