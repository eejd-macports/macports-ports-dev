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
#
# What this cannot detect: an edit that changes a file's contents while leaving the file count
# and every mtime alone. Nothing in MacPorts does that -- reinplace rewrites through a
# temporary file and patch(1) updates mtimes -- but a Portfile that wrote a file and then
# restored its mtime by hand would defeat the check. Such a port should set
# cargo.vendor_shared no.
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
#
# This changes what every Rust port records, not only ports using the shared tree: the previous
# default mapped the port's own directories to the empty string, so a source path appeared as
# "src/lib.rs", and it now appears as "/macports/build/<port>/work/.../src/lib.rs". A port that
# sets rust.remap itself is unaffected.
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

# The rust.remap default, read out of the port's context. Kept separate from default_remap so the
# policy above stays testable without a port, and so a base that predates rustcache_dir still gets
# the build-root rule.
proc rust::remap_default {} {
    global portdbpath rustcache_dir
    set build_root ""
    if {[info exists portdbpath]} {
        set build_root [file join $portdbpath build]
    }
    set vendor_dir ""
    if {[info exists rustcache_dir]} {
        set vendor_dir [file join $rustcache_dir vendor]
    }
    return [rust::default_remap $build_root $vendor_dir]
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

####################################################################################################
# Shared vendor tree
#
# Every port extracts its own private copy of the crates it depends on, so two ports that share a
# dependency compile it from two different absolute paths. cargo passes rustc the absolute path of
# the crate source and sets the process working directory to the crate's own directory, and sccache
# hashes both -- so identical crates compiled by different ports never share a cache entry.
#
# The fix is to compile the shared ones from one place. After extraction, crates that are still
# byte-for-byte what the .crate contained are moved into a tree under rustcache_dir and cargo's
# directory source is pointed at it. Crates a port has modified stay private and are reached with
# cargo's `paths` overrides instead, which take precedence over the directory source and remain
# compatible with --frozen.
####################################################################################################

# Where the signatures taken at extract time are kept between phases. Deliberately a sibling of the
# directory source rather than a file inside it, so cargo never has to skip over it.
proc rust::vendor_signature_file {cargo_home} {
    return [file join $cargo_home vendor-signatures]
}

# Signatures accumulated during extraction, keyed by crate directory name.
variable pristine_signatures [dict create]

# Take a crate's signature while it is still exactly what the .crate contained.
#
# This has to happen before rust::old_macos_compatibility runs, not after the whole extract
# phase. Two of its branches -- kqueue below 1.0.5 on an i386 build, and curl-sys below 0.4.56
# -- sit above its `macosx_deployment_target >= 10.8` early return and therefore fire on any
# deployment target. A signature taken afterwards would match the patched crate, the crate
# would be classified pristine, and this port's patched copy would be published for every
# other port to compile against.
proc rust::note_pristine_signature {cargo_home name} {
    variable pristine_signatures
    dict set pristine_signatures $name \
        [rust::vendor_signature [file join $cargo_home macports $name]]
}

# Persist what was accumulated, so the configure phase can read it back in a later `port`
# invocation.
proc rust::record_vendor_signatures {cargo_home} {
    variable pristine_signatures
    set fd [open [rust::vendor_signature_file $cargo_home] w]
    puts -nonewline $fd $pristine_signatures
    close $fd
    return $pristine_signatures
}

proc rust::read_vendor_signatures {cargo_home} {
    set path [rust::vendor_signature_file $cargo_home]
    if {![file exists $path]} {
        return [dict create]
    }
    set fd [open $path r]
    set data [read $fd]
    close $fd
    if {[catch {dict size $data}]} {
        return [dict create]
    }
    return $data
}

# The "package" checksum a crate directory carries, or "" if it has none. Two directories with the
# same name and the same package checksum hold the same crate.
proc rust::crate_package_checksum {dir} {
    set path [file join $dir .cargo-checksum.json]
    if {![file exists $path]} {
        return ""
    }
    set fd [open $path r]
    set text [read $fd]
    close $fd
    if {[regexp {"package"\s*:\s*(?:"([^"]*)"|null)} $text -> value]} {
        return $value
    }
    return ""
}

# Move a crate directory into the shared tree, and return 1 if the shared tree ends up holding this
# crate. Staging plus rename means a concurrent build never sees a half-copied crate; a rename that
# loses the race is not an error, because the winner published the same bytes.
proc rust::publish_crate {vendor_dir crate_dir} {
    set name [file tail $crate_dir]
    set target [file join $vendor_dir $name]

    # Read the checksum before anything moves, so it stays available on every path below.
    set ours [rust::crate_package_checksum $crate_dir]

    if {[file isdirectory $target]} {
        # Already published. Only reuse it if it really is the same crate: a name collision with
        # different contents has to stay private, or one port would compile the other's source.
        return [expr {[rust::crate_package_checksum $target] eq $ours}]
    }

    # A leading dot keeps the staging directory invisible to cargo's directory source, which skips
    # hidden entries, so a build running concurrently never tries to parse a partial crate.
    set staging [file join $vendor_dir ".tmp-${name}-[pid]"]
    file delete -force -- $staging
    if {[catch {file rename -- $crate_dir $staging}]} {
        # Different filesystem, most likely; fall back to copying.
        if {[catch {file copy -- $crate_dir $staging} result]} {
            ui_debug "Rust cache: could not stage ${name}: ${result}"
            file delete -force -- $staging
            return 0
        }
    }
    if {[catch {file rename -- $staging $target}]} {
        if {[file isdirectory $target] && [rust::crate_package_checksum $target] eq $ours} {
            # Another port published the same crate first.
            file delete -force -- $staging
            return 1
        }
        # The shared tree does not have this crate and this port still needs it, so put the
        # copy back where the port expects to find it before giving up.
        if {![file isdirectory $crate_dir]} {
            if {[catch {file rename -- $staging $crate_dir}]} {
                catch {file copy -- $staging $crate_dir}
            }
        }
        file delete -force -- $staging
        return 0
    }
    return 1
}

# Remove staging directories left behind by an interrupted build. Anything still present after a day
# cannot belong to a live build.
proc rust::sweep_stale_staging {vendor_dir {max_age 86400}} {
    set now [clock seconds]
    foreach path [glob -nocomplain -directory $vendor_dir -types d -- .tmp-*] {
        if {[catch {file mtime $path} mtime]} {
            continue
        }
        if {$now - $mtime > $max_age} {
            catch {file delete -force -- $path}
        }
    }
}

# Warn when Cargo.lock names a registry dependency that cargo.crates does not. Sharing the vendor
# tree makes such a crate more likely to be silently satisfied by another port's copy instead of
# failing the build, so the drift is reported rather than left to be discovered later.
proc rust::warn_lockfile_drift {lockfile crates} {
    if {![file exists $lockfile]} {
        return
    }
    set declared [dict create]
    foreach {cname cversion chksum} $crates {
        dict set declared ${cname}-${cversion} 1
    }
    set fd [open $lockfile r]
    set text [read $fd]
    close $fd

    set missing [list]
    set cname ""
    set cversion ""
    foreach line [split $text \n] {
        set line [string trim $line]
        if {$line eq "\[\[package\]\]"} {
            set cname ""
            set cversion ""
        } elseif {[regexp {^name\s*=\s*"([^"]*)"} $line -> value]} {
            set cname $value
        } elseif {[regexp {^version\s*=\s*"([^"]*)"} $line -> value]} {
            set cversion $value
        } elseif {[regexp {^source\s*=\s*"registry\+} $line]} {
            if {$cname ne "" && $cversion ne "" && ![dict exists $declared ${cname}-${cversion}]} {
                lappend missing ${cname}-${cversion}
            }
        }
    }
    if {[llength $missing] > 0} {
        ui_warn "Cargo.lock names registry crates that cargo.crates does not declare: [join [lsort -unique $missing] {, }]"
    }
}


# Decide which of a port's crates can be compiled from the shared tree.
#
# Pure: takes the facts and returns the decision, so the policy can be tested without extracting
# anything. `spec` keys:
#   crates       the port's cargo.crates list (name version checksum triples)
#   source_dir   directory the crates were extracted into
#   github_dirs  directory names that came from cargo.crates_github rather than crates.io
#   signatures   dict of directory name -> signature recorded at extract time
#
# Returns a dict:
#   shared    directory names that are byte-for-byte the published crate
#   private   directory names that must stay in this port's own tree
#   fallback  reason the whole port has to keep its private tree, or "" to proceed
#
# The fallback exists because cargo matches a `paths` override by package *name* only
# (registry.rs: Dependency::new_override takes the name and no version requirement). If a port has
# modified one version of a crate while another version of the same crate is also in its graph, an
# override for the modified copy would capture both, so the whole port keeps its private tree.
# Copy already-published crates back into the port's own tree, for when vendor_switch gives up
# the shared tree after it has started publishing. The crates stay in the shared tree as well:
# publish_crate leaves a copy there, other ports may already be resolving against it, and it is
# content-addressed, so a second copy here is not a divergence.
#
# A crate whose directory is already present is left alone -- the caller only lists crates whose
# port-local copy it deleted, so anything back in place got there by some other route and is not
# ours to overwrite.
#
# Failures are reported and skipped rather than raised. This is already the recovery path, and a
# Tcl error escaping vendor_switch would replace a partial tree with a confusing exception; but a
# silent failure leaves cargo pointed at a missing or half-written crate directory and only its
# own opaque resolve error to explain it, so name the crate that did not come back.
#
# Returns the crates it could not restore.
proc rust::restore_published {vendor_dir source_dir published} {
    set failed [list]
    foreach done $published {
        if {[file isdirectory [file join $source_dir $done]]} {
            continue
        }
        if {[catch {file copy -- [file join $vendor_dir $done] \
                                 [file join $source_dir $done]} result]} {
            ui_warn "Rust cache: could not restore ${done} to this port's own crate tree:\
                     ${result}"
            lappend failed $done
        }
    }
    return $failed
}

proc rust::plan_vendor_switch {spec} {
    foreach key {crates source_dir github_dirs signatures} {
        if {![dict exists $spec $key]} {
            dict set spec $key {}
        }
    }
    set source_dir [dict get $spec source_dir]
    set github_dirs [dict get $spec github_dirs]
    set signatures [dict get $spec signatures]

    # Directory name -> crate name, so an override's blast radius can be judged exactly rather than
    # by guessing where the version starts in a name that may itself contain dashes.
    set crate_name [dict create]
    set versions_of [dict create]
    foreach {cname cversion chksum} [dict get $spec crates] {
        dict set crate_name ${cname}-${cversion} $cname
        dict lappend versions_of $cname $cversion
    }

    set shared [list]
    set private [list]
    foreach dir [lsort [glob -nocomplain -directory $source_dir -types d -- *]] {
        set name [file tail $dir]
        if {$name in $github_dirs} {
            # Not a crates.io crate: it is reached through a git source, and its directory is not
            # named the way a shared tree entry would be.
            continue
        }
        if {![dict exists $signatures $name] || [dict get $signatures $name] ne [rust::vendor_signature $dir]} {
            # Either never recorded, or modified after extraction by a reinplace or a patch.
            lappend private $name
            continue
        }
        lappend shared $name
    }

    set fallback ""
    foreach name $private {
        if {![dict exists $crate_name $name]} {
            set fallback "crate directory ${name} does not correspond to a declared crate"
            break
        }
        set cname [dict get $crate_name $name]
        if {[llength [dict get $versions_of $cname]] > 1} {
            set fallback "modified crate ${name} shares its name with another version in this port"
            break
        }
    }

    set ambiguous [list]
    dict for {cname versions} $versions_of {
        if {[llength $versions] > 1} {
            lappend ambiguous $cname
        }
    }

    return [dict create shared $shared private $private fallback $fallback \
        crate_name $crate_name ambiguous $ambiguous]
}

# Move this port onto the shared vendor tree, if it can use one.
#
# Runs as a pre-configure: by then rustcache_dir exists (base creates it in configure_start, which
# runs even for ports with use_configure no) and the compiler wrappers have been written by
# compiler_wrapper's post-extract, but nothing has been compiled yet.
proc rust::vendor_switch {} {
    global cargo.home cargo.crates cargo.crates_github cargo.vendor_shared cargo.update \
           configure.rustcache rustcache_dir prefix worksrcpath

    set source_dir [file join ${cargo.home} macports]

    rust::warn_lockfile_drift [file join ${worksrcpath} Cargo.lock] ${cargo.crates}

    set reason ""
    if {[llength ${cargo.crates}] == 0} {
        set reason "the port declares no crates"
    } elseif {![tbool cargo.vendor_shared]} {
        set reason "cargo.vendor_shared is off"
    } elseif {![tbool configure.rustcache]} {
        set reason "the Rust cache is off"
    } elseif {[tbool cargo.update]} {
        set reason "cargo.update rewrites the lockfile, so the extracted crates are not authoritative"
    } elseif {[option os.platform] eq "darwin" && [vercmp [option macosx_deployment_target] < 10.8]} {
        set reason "the deployment target predates 10.8, where crates are rewritten in place"
    } elseif {![file isdirectory $source_dir]} {
        set reason "no crates were extracted"
    }
    if {$reason eq ""} {
        set vendor_dir [file join ${rustcache_dir} vendor]
        if {[catch {file mkdir $vendor_dir} result]} {
            set reason "the shared vendor tree could not be created: ${result}"
        }
    }
    if {$reason ne ""} {
        ui_debug "Rust cache: keeping this port's own crate tree because ${reason}"
        return
    }

    rust::sweep_stale_staging $vendor_dir

    set github_dirs [list]
    set git_sources [list]
    foreach {cname cgithub cbranch crevision chksum} ${cargo.crates_github} {
        lappend github_dirs "[lindex [split ${cgithub} /] 1]-${crevision}"
        lappend git_sources [list "https://github.com/${cgithub}" ${cbranch} macports-local]
    }

    set plan [rust::plan_vendor_switch [dict create \
        crates ${cargo.crates} \
        source_dir $source_dir \
        github_dirs $github_dirs \
        signatures [rust::read_vendor_signatures ${cargo.home}]]]

    if {[dict get $plan fallback] ne ""} {
        ui_debug "Rust cache: keeping this port's own crate tree because [dict get $plan fallback]"
        return
    }

    set published [list]
    set stranded [list]
    foreach name [dict get $plan shared] {
        if {[rust::publish_crate $vendor_dir [file join $source_dir $name]]} {
            lappend published $name
            # publish_crate moved it; drop any copy a fallback left behind.
            file delete -force -- [file join $source_dir $name]
        } else {
            # The shared tree does not hold this crate -- a name collision with different
            # contents, or a staging failure. publish_crate guarantees the port's own copy is
            # still there, so override it like a modified crate rather than leaving cargo with
            # no path to it at all: config.toml is about to point crates.io exclusively at the
            # shared tree, and local-registry is poisoned, so an unlisted crate is unreachable.
            lappend stranded $name
        }
    }

    # A crate that could not be published is about to be reached through a `paths` override, and
    # cargo matches an override by package name alone. If this port's graph holds more than one
    # version of that name, the override would capture both -- the same hazard plan_vendor_switch
    # refuses to accept for a modified crate. It cannot be foreseen, because whether a crate can
    # be published is only known here, so the port gives up the shared tree entirely and the
    # crates already published are copied back.
    foreach name $stranded {
        set cname ""
        if {[dict exists [dict get $plan crate_name] $name]} {
            set cname [dict get [dict get $plan crate_name] $name]
        }
        # $cname eq "" is a defensive guard, not an expected edge case: a crate only reaches
        # $stranded by way of `shared`, and plan_vendor_switch can only classify a crate shared
        # if import_crate recorded a signature for it, which it does only for declared crates --
        # every one of which is in crate_name. Reaching it means that invariant broke, which is a
        # different and louder problem than the ambiguity below, so say so separately.
        if {$cname eq ""} {
            ui_warn "Rust cache: ${name} is shared but is not a declared crate; giving up the\
                     shared tree for this port"
        } elseif {$cname in [dict get $plan ambiguous]} {
            ui_warn "Rust cache: ${name} could not be shared and its name is not unique in this\
                     port; falling back to this port's own crate tree"
        } else {
            continue
        }
        rust::restore_published $vendor_dir $source_dir $published
        return
    }

    # Anything cargo must still find in this port's own tree: crates it modified, crates that
    # could not be shared, and the git checkouts, which are not crates.io packages at all.
    set overrides [list]
    foreach name [concat [dict get $plan private] $stranded] {
        lappend overrides [file join $source_dir $name]
    }

    set targets [list]
    foreach arch {arm64 x86_64 i386 ppc ppc64} {
        lappend targets [list [option triplet.${arch}] \
            [rust::shared_linker ${rustcache_dir} [compwrap::wrap_compiler ld]]]
    }

    set conf [open "${cargo.home}/config.toml" w]
    puts -nonewline $conf [rust::render_cargo_config [dict create \
        paths $overrides \
        sources [dict create \
            directory $vendor_dir \
            local_directory $source_dir \
            git $git_sources] \
        build [dict create \
            rustc "${prefix}/bin/rustc" \
            rustflags [option rust.flags]] \
        targets $targets]]
    close $conf

    ui_debug "Rust cache: [llength $published] crates shared, [llength $overrides] kept private"
    if {[llength $stranded] > 0} {
        ui_debug "Rust cache: could not share [join $stranded {, }]"
    }
}
