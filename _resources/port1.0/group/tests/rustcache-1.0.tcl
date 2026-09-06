#!/usr/bin/env tclsh
# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:ft=tcl:et:sw=4:ts=4:sts=4

package require tcltest 2
namespace import tcltest::*
::tcltest::configure {*}$::argv

set testdir [file dirname [file normalize [info script]]]

proc evaluate_rustcache_contract {group enabled {test_subport rustcache-test}} {
    set child [interp create]
    try {
        $child eval {
            namespace eval port {
                proc register_callback {args} {}
            }
            namespace eval portconfigure {
                proc should_add_stdlib {} {}
                proc should_add_cxx_abi {} {}
            }

            proc unknown {args} {}
            proc PortGroup {args} {}
            proc options {args} {}
            set default_values {}
            proc default {name args} {
                dict set ::default_values $name $args
            }
            proc tbool {name} {
                upvar $name value
                return [expr {[info exists value] && [string is true -strict $value]}]
            }
            proc option {name} {
                variable option_values
                return [dict get $option_values $name]
            }

            set build_dependencies {}
            proc depends_build-delete {value} {}
            proc depends_build-append {value} {
                lappend ::build_dependencies $value
            }
            proc depends_skip_archcheck-delete {value} {}
            proc depends_skip_archcheck-append {value} {}
            foreach phase {configure build destroot} {
                proc ${phase}.env-delete {value} {}
                proc ${phase}.env-append {value} "lappend ::${phase}_environment \$value"
                set ${phase}_environment {}
            }
        }

        $child eval [list source $group]
        $child eval [list set configure.rustcache $enabled]
        $child eval [list set subport $test_subport]
        $child eval {
            set prefix /opt/local
            set rustcache_size 20G
            set rustcache_dir /var/macports/build/.rustcache
            set option_values [dict create \
                openssl.branch {} \
                os.platform linux \
                configure.compiler clang \
                macosx_deployment_target 14.0 \
                os.major 20 \
                rust.remap {} \
                rust.llvm.legacy 0 \
                rust.use_cctools 0]
            rust::rust_pg_callback
            list [expr {[lsearch -exact $build_dependencies port:sccache] >= 0}] \
                $configure_environment \
                $build_environment \
                $destroot_environment \
                [dict exists $default_values compwrap.ccache_supported_compilers] \
                ${configure.rustcache} \
                [expr {[tbool configure.rustcache] && [namespace exists ::rust]}]
        }
    } finally {
        interp delete $child
    }
}

set cache_environment [list \
    RUSTC_WRAPPER=/opt/local/bin/sccache \
    SCCACHE_CACHE_SIZE=20G \
    SCCACHE_DIR=/var/macports/build/.rustcache/sccache \
    SCCACHE_SERVER_UDS=/var/macports/build/.rustcache/sccache.sock \
    CARGO_INCREMENTAL=0]

foreach group_name {rust-1.0.tcl cargo_fetch-1.0.tcl} {
    set group [file join $testdir .. $group_name]

    test rustcache-enabled-$group_name {
        Enabling the global Rust cache after PortGroup loading adds sccache to every build phase.
    } -body {
        evaluate_rustcache_contract $group yes
    } -result [list 1 $cache_environment $cache_environment $cache_environment 0 yes 1]

    test rustcache-disabled-$group_name {
        A Portfile can disable the global Rust cache after PortGroup loading.
    } -body {
        evaluate_rustcache_contract $group no
    } -result {0 {} {} {} 0 no 0}

    foreach toolchain_subport {rust cargo sccache rust-bootstrap rust-bootstrap-dev} {
        test rustcache-toolchain-$toolchain_subport-$group_name {
            Toolchain and cache ports cannot depend on or run through sccache without creating dependency cycles.
        } -body {
            evaluate_rustcache_contract $group yes $toolchain_subport
        } -result {0 {} {} {} 0 no 0}
    }
}

####################################################################################################
# Shared helpers (rust_cache-1.0.tcl). These are pure, so they are exercised directly rather than
# through a PortGroup evaluation.
####################################################################################################

source [file join $testdir .. rust_cache-1.0.tcl]

# The exact text the PortGroups emitted before render_cargo_config existed. Any
# change to this string is a change to what cargo sees, not a refactor.
set legacy_sources_config "\[source\]
\[source.macports\]
directory = \"/work/.home/.cargo/macports\"
\[source.crates-io\]
replace-with = \"macports\"
local-registry = \"/var/empty\"
\[source.\"https://github.com/example/dep\"\]
git = \"https://github.com/example/dep\"
branch = \"main\"
replace-with = \"macports\"
"

set legacy_build_config "\[build\]
rustc = \"/opt/local/bin/rustc\"
rustflags = \[\"--remap-path-prefix=/work=\", \"-Clink-arg=-Wl,-headerpad_max_install_names\"\]
\[target.aarch64-apple-darwin\]
linker = \"/work/compwrap/ld/usr/bin/ld\"
"

test render-cargo-config-sources-matches-legacy-output {
    The source half renders byte-for-byte what the PortGroups wrote by hand.
} -body {
    rust::render_cargo_config [dict create \
        sources [dict create \
            directory /work/.home/.cargo/macports \
            git [list [list https://github.com/example/dep main macports]]]]
} -result $legacy_sources_config

test render-cargo-config-build-matches-legacy-output {
    The build half renders byte-for-byte what the PortGroups wrote by hand.
} -body {
    rust::render_cargo_config [dict create \
        build [dict create \
            rustc /opt/local/bin/rustc \
            rustflags {--remap-path-prefix=/work= -Clink-arg=-Wl,-headerpad_max_install_names}] \
        targets [list [list aarch64-apple-darwin /work/compwrap/ld/usr/bin/ld]]]
} -result $legacy_build_config

test render-cargo-config-omits-absent-sections {
    A section is emitted only when its key is present, and rustflags is dropped when empty.
} -body {
    list \
        [rust::render_cargo_config [dict create]] \
        [rust::render_cargo_config [dict create \
            build [dict create rustc /opt/local/bin/rustc rustflags {}]]]
} -result [list {} "\[build\]\nrustc = \"/opt/local/bin/rustc\"\n"]

test render-cargo-config-paths-precede-every-table {
    cargo's `paths` overrides are a top-level TOML key, so they must be emitted before
    the first table header or the file does not parse as intended.
} -body {
    set text [rust::render_cargo_config [dict create \
        paths {/work/a-1.0 /work/b-2.0} \
        sources [dict create directory /shared/vendor]]]
    list \
        [lindex [split $text \n] 0] \
        [expr {[string first "paths = " $text] < [string first "\[source\]" $text]}]
} -result [list {paths = ["/work/a-1.0", "/work/b-2.0"]} 1]

test render-cargo-config-second-directory-source {
    Crates that cannot be shared get a second directory source, and a git dependency can be
    redirected at it by name while crates.io still resolves through the shared one.
} -body {
    set text [rust::render_cargo_config [dict create \
        sources [dict create \
            directory /shared/vendor \
            local_directory /work/.home/.cargo/macports \
            git [list [list https://github.com/example/dep main macports-local]]]]]
    split [string trimright $text \n] \n
} -result [list \
    {[source]} \
    {[source.macports]} \
    {directory = "/shared/vendor"} \
    {[source.macports-local]} \
    {directory = "/work/.home/.cargo/macports"} \
    {[source.crates-io]} \
    {replace-with = "macports"} \
    {local-registry = "/var/empty"} \
    {[source."https://github.com/example/dep"]} \
    {git = "https://github.com/example/dep"} \
    {branch = "main"} \
    {replace-with = "macports-local"}]

test default-remap-orders-vendor-last {
    rustc applies the last matching --remap-path-prefix, so the more specific vendor rule
    must follow the build-root rule, and both map onto fixed tokens rather than the empty
    string so that the rustc command line is the same in every port.
} -body {
    rust::default_remap /var/macports/build /var/macports/build/.rustcache/vendor
} -result {/var/macports/build /macports/build /var/macports/build/.rustcache/vendor /macports/vendor}

test remap-default-reads-the-port-context {
    The rust.remap default is derived from the port's own configuration, and a base that has no
    rustcache_dir still gets the build-root rule rather than an error.
} -setup {
    set saved [list [info exists ::portdbpath] [info exists ::rustcache_dir]]
    set ::portdbpath /var/macports
    set ::rustcache_dir /var/macports/build/.rustcache
} -body {
    set both [rust::remap_default]
    unset ::rustcache_dir
    set only_build [rust::remap_default]
    unset ::portdbpath
    list $both $only_build [rust::remap_default]
} -cleanup {
    unset -nocomplain ::portdbpath ::rustcache_dir
} -result {{/var/macports/build /macports/build /var/macports/build/.rustcache/vendor /macports/vendor} {/var/macports/build /macports/build} {}}

test default-remap-skips-empty-inputs {
    A port with no shared vendor tree gets only the build-root rule.
} -body {
    list \
        [rust::default_remap /var/macports/build {}] \
        [rust::default_remap {} {}]
} -result {{/var/macports/build /macports/build} {}}

test vendor-signature-detects-mutation {
    A crate directory that a port has modified in place no longer matches the signature taken
    right after extraction, while writing .cargo-checksum.json -- which the PortGroup always
    does -- leaves the signature alone.
} -setup {
    set crate [makeDirectory signature_crate]
    makeFile "fn main() {}" main.rs $crate
    makeDirectory src $crate
    makeFile "pub fn f() {}" lib.rs [file join $crate src]
} -body {
    set pristine [rust::vendor_signature $crate]

    # The PortGroup writes this after extraction; it must not count as a mutation.
    makeFile "{\"package\": \"abc\", \"files\": {}}" .cargo-checksum.json $crate
    set after_checksum [rust::vendor_signature $crate]

    # A reinplace on a source file must count as one.
    set fd [open [file join $crate src lib.rs] w]
    puts $fd "pub fn f() { /* patched */ }"
    close $fd
    file mtime [file join $crate src lib.rs] [expr {[lindex $pristine 1] + 60}]
    set after_reinplace [rust::vendor_signature $crate]

    list \
        [lindex $pristine 0] \
        [expr {$after_checksum eq $pristine}] \
        [expr {$after_reinplace ne $pristine}]
} -cleanup {
    file delete -force -- $crate
} -result {2 1 1}

test vendor-signature-of-missing-directory {
    A crate that was never extracted has an empty signature rather than an error.
} -body {
    rust::vendor_signature [file join $testdir does-not-exist]
} -result {0 0}

if {![catch {package require Pextlib 1.0}]} {
    test shared-linker-is-content-addressed {
        Two ports whose linker wrappers have identical contents resolve to one shared path, and
        a wrapper with different contents resolves to a different one -- so `-C linker=` stops
        being a per-port input to the cache key without merging wrappers that really differ.
    } -setup {
        set cache [makeDirectory shared_linker_cache]
        set port_a [makeDirectory shared_linker_a]
        set port_b [makeDirectory shared_linker_b]
        set port_c [makeDirectory shared_linker_c]
        makeFile "#!/bin/sh\nexec /usr/bin/ld \"\$@\"\n" ld $port_a
        makeFile "#!/bin/sh\nexec /usr/bin/ld \"\$@\"\n" ld $port_b
        makeFile "#!/bin/sh\nexec /usr/bin/ld -w \"\$@\"\n" ld $port_c
    } -body {
        set a [rust::shared_linker $cache [file join $port_a ld]]
        set b [rust::shared_linker $cache [file join $port_b ld]]
        set c [rust::shared_linker $cache [file join $port_c ld]]
        list \
            [expr {$a eq $b}] \
            [expr {$a ne $c}] \
            [expr {[string first [file join $cache compwrap] $a] == 0}] \
            [file executable $a] \
            [llength [glob -nocomplain -directory [file join $cache compwrap] *]]
    } -cleanup {
        file delete -force -- $cache $port_a $port_b $port_c
    } -result {1 1 1 1 2}

    test shared-linker-passes-through-a-missing-wrapper {
        A port with no wrapper to publish keeps whatever path it was given.
    } -setup {
        set cache [makeDirectory shared_linker_missing_cache]
    } -body {
        rust::shared_linker $cache /nonexistent/compwrap/ld
    } -cleanup {
        file delete -force -- $cache
    } -result {/nonexistent/compwrap/ld}
}

####################################################################################################
# Shared vendor tree
####################################################################################################

# Build a crate tree on disk and return {source_dir signatures}. Each crate is given as
# {dirname content}; a content of "" means the crate is created and then modified afterwards, which
# is how a reinplace or a Portfile patch looks to the signature check.
proc make_crate_tree {label crates} {
    set source_dir [makeDirectory ${label}_macports]
    foreach {name content} $crates {
        set dir [makeDirectory $name $source_dir]
        makeFile "// ${name}" lib.rs $dir
        makeFile "\[package\]\nname = \"${name}\"\n" Cargo.toml $dir
    }
    set signatures [dict create]
    foreach dir [glob -nocomplain -directory $source_dir -types d -- *] {
        dict set signatures [file tail $dir] [rust::vendor_signature $dir]
    }
    return [list $source_dir $signatures]
}

proc touch_crate {source_dir name} {
    set path [file join $source_dir $name lib.rs]
    set fd [open $path a]
    puts $fd "// patched"
    close $fd
    file mtime $path [expr {[clock seconds] + 120}]
}

test plan-vendor-switch-shares-pristine-and-keeps-modified {
    A crate still identical to the extracted .crate is shared; one the port modified in place is
    kept private so the modification cannot leak into another port's build.
} -setup {
    lassign [make_crate_tree plan_basic {serde-1.0.0 {} libc-0.2.0 {} kqueue-1.0.4 {}}] source_dir signatures
    touch_crate $source_dir kqueue-1.0.4
} -body {
    set plan [rust::plan_vendor_switch [dict create \
        crates {serde 1.0.0 aaa libc 0.2.0 bbb kqueue 1.0.4 ccc} \
        source_dir $source_dir \
        signatures $signatures]]
    list [dict get $plan shared] [dict get $plan private] [dict get $plan fallback]
} -cleanup {
    file delete -force -- $source_dir
} -result {{libc-0.2.0 serde-1.0.0} kqueue-1.0.4 {}}

test plan-vendor-switch-excludes-github-crates {
    Crates fetched from a git source are neither shared nor overridden: they stay in the port's own
    directory source, which is where their git source replacement points.
} -setup {
    lassign [make_crate_tree plan_github {serde-1.0.0 {} dep-abc123 {}}] source_dir signatures
} -body {
    set plan [rust::plan_vendor_switch [dict create \
        crates {serde 1.0.0 aaa} \
        source_dir $source_dir \
        github_dirs {dep-abc123} \
        signatures $signatures]]
    list [dict get $plan shared] [dict get $plan private]
} -cleanup {
    file delete -force -- $source_dir
} -result {serde-1.0.0 {}}

test plan-vendor-switch-falls-back-when-an-override-would-be-ambiguous {
    cargo matches a `paths` override by package name alone, so a port that modified one version of
    a crate while another version of the same crate is also in its graph cannot use overrides at
    all -- the override would capture both. The whole port keeps its private tree.
} -setup {
    lassign [make_crate_tree plan_ambiguous {syn-1.0.109 {} syn-2.0.48 {} serde-1.0.0 {}}] source_dir signatures
    touch_crate $source_dir syn-1.0.109
} -body {
    set plan [rust::plan_vendor_switch [dict create \
        crates {syn 1.0.109 aaa syn 2.0.48 bbb serde 1.0.0 ccc} \
        source_dir $source_dir \
        signatures $signatures]]
    expr {[dict get $plan fallback] ne ""}
} -cleanup {
    file delete -force -- $source_dir
} -result 1

test plan-vendor-switch-keeps-a-crate-with-no-recorded-signature {
    Without a signature there is no evidence the crate is pristine, so it is not shared.
} -setup {
    lassign [make_crate_tree plan_unrecorded {serde-1.0.0 {} libc-0.2.0 {}}] source_dir signatures
    dict unset signatures libc-0.2.0
} -body {
    set plan [rust::plan_vendor_switch [dict create \
        crates {serde 1.0.0 aaa libc 0.2.0 bbb} \
        source_dir $source_dir \
        signatures $signatures]]
    list [dict get $plan shared] [dict get $plan private] [dict get $plan fallback]
} -cleanup {
    file delete -force -- $source_dir
} -result {serde-1.0.0 libc-0.2.0 {}}

test publish-crate-is-idempotent-and-refuses-a-name-collision {
    Publishing the same crate twice is a no-op, and a directory that has the same name but a
    different package checksum is never treated as the same crate.
} -setup {
    set vendor [makeDirectory publish_vendor]
    set port_a [makeDirectory publish_a]
    set port_b [makeDirectory publish_b]
    set port_c [makeDirectory publish_c]
    foreach {root chksum} [list $port_a \"aaa\" $port_b \"aaa\" $port_c \"zzz\"] {
        set dir [makeDirectory serde-1.0.0 $root]
        makeFile "// serde" lib.rs $dir
        makeFile "{\"package\": ${chksum}, \"files\": {}}" .cargo-checksum.json $dir
    }
} -body {
    set first [rust::publish_crate $vendor [file join $port_a serde-1.0.0]]
    set second [rust::publish_crate $vendor [file join $port_b serde-1.0.0]]
    set collision [rust::publish_crate $vendor [file join $port_c serde-1.0.0]]
    list \
        $first $second $collision \
        [file isdirectory [file join $vendor serde-1.0.0]] \
        [file exists [file join $port_a serde-1.0.0]] \
        [llength [glob -nocomplain -directory $vendor -types d -- .tmp-*]]
} -cleanup {
    file delete -force -- $vendor $port_a $port_b $port_c
} -result {1 1 0 1 0 0}

test sweep-stale-staging-removes-only-abandoned-directories {
    Staging left by an interrupted build is cleaned up; staging from a build that may still be
    running is left alone, as is a published crate.
} -setup {
    set vendor [makeDirectory sweep_vendor]
    makeDirectory .tmp-serde-1.0.0-111 $vendor
    makeDirectory .tmp-libc-0.2.0-222 $vendor
    makeDirectory serde-1.0.0 $vendor
    file mtime [file join $vendor .tmp-serde-1.0.0-111] [expr {[clock seconds] - 172800}]
} -body {
    rust::sweep_stale_staging $vendor
    lsort [lmap path [glob -nocomplain -directory $vendor -types d -- * .tmp-*] {file tail $path}]
} -cleanup {
    file delete -force -- $vendor
} -result {.tmp-libc-0.2.0-222 serde-1.0.0}

test vendor-signatures-survive-between-phases {
    Extraction and configuration can run in separate `port` invocations, so the signatures are
    written to disk rather than kept in the interpreter.
} -setup {
    set cargo_home [makeDirectory signatures_home]
    lassign [make_crate_tree signature_roundtrip {serde-1.0.0 {}}] tree _
    file rename $tree [file join $cargo_home macports]
} -body {
    rust::note_pristine_signature $cargo_home serde-1.0.0
    set written [rust::record_vendor_signatures $cargo_home]
    set read_back [rust::read_vendor_signatures $cargo_home]
    list \
        [expr {$written eq $read_back}] \
        [dict exists $read_back serde-1.0.0] \
        [rust::read_vendor_signatures [makeDirectory signatures_empty]]
} -cleanup {
    file delete -force -- $cargo_home
    set ::rust::pristine_signatures [dict create]
} -result {1 1 {}}

test warn-lockfile-drift-reports-undeclared-registry-crates {
    A registry dependency in Cargo.lock that cargo.crates does not declare is reported, because a
    shared vendor tree makes it likelier to be satisfied silently by another port's copy. Git and
    workspace-local packages have no registry source and are not reported.
} -setup {
    set lockfile [makeFile {
[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "libc"
version = "0.2.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "mytool"
version = "0.1.0"

[[package]]
name = "gitdep"
version = "0.1.0"
source = "git+https://github.com/example/dep?branch=main#abc123"
} Cargo.lock]
    set warnings [list]
    if {[llength [info commands ui_warn]]} {
        rename ui_warn ui_warn_saved
    }
    proc ui_warn {msg} {lappend ::warnings $msg}
} -body {
    rust::warn_lockfile_drift $lockfile {serde 1.0.0 aaa}
    rust::warn_lockfile_drift [file join $testdir no-such-lockfile] {}
    set warnings
} -cleanup {
    rename ui_warn {}
    if {[llength [info commands ui_warn_saved]]} {
        rename ui_warn_saved ui_warn
    }
    file delete -force -- $lockfile
} -result {{Cargo.lock names registry crates that cargo.crates does not declare: libc-0.2.0}}

test signature-is-taken-before-a-crate-can-be-patched {
    rust::old_macos_compatibility rewrites some crates in place, and two of its branches
    (kqueue below 1.0.5 on an i386 build, curl-sys below 0.4.56) sit above its
    macosx_deployment_target early return, so they fire on any deployment target. If the
    signature were taken after the extract phase rather than at import time, a patched crate
    would match its own baseline, be classified pristine, and be published for every other
    port to compile against.
} -setup {
    set ::rust::pristine_signatures [dict create]
    set cargo_home [makeDirectory patched_home]
    set source_dir [makeDirectory macports $cargo_home]
    set crate [makeDirectory curl-sys-0.4.55 $source_dir]
    makeFile "// build" build.rs $crate
    makeFile "{\"package\": \"aaa\", \"files\": {}}" .cargo-checksum.json $crate
} -body {
    # What import_crate now does: signature first, patch second.
    rust::note_pristine_signature $cargo_home curl-sys-0.4.55
    set fd [open [file join $crate build.rs] a]
    puts $fd "// macports: Command::new(\"clang\") rewritten"
    close $fd
    file mtime [file join $crate build.rs] [expr {[clock seconds] + 120}]

    set plan [rust::plan_vendor_switch [dict create \
        crates {curl-sys 0.4.55 aaa} \
        source_dir $source_dir \
        signatures [rust::record_vendor_signatures $cargo_home]]]
    list [dict get $plan shared] [dict get $plan private]
} -cleanup {
    file delete -force -- $cargo_home
    set ::rust::pristine_signatures [dict create]
} -result {{} curl-sys-0.4.55}

test publish-crate-restores-the-port-copy-when-it-cannot-publish {
    A crate that cannot reach the shared tree must still be where the port left it. Once
    config.toml points crates.io exclusively at the shared tree and poisons local-registry, a
    crate that is in neither place is unreachable and the build fails with no useful message.
} -setup {
    set vendor [makeDirectory restore_vendor]
    set port_a [makeDirectory restore_a]
    set crate [makeDirectory serde-1.0.0 $port_a]
    makeFile "// serde" lib.rs $crate
    makeFile "{\"package\": \"aaa\", \"files\": {}}" .cargo-checksum.json $crate
    # A plain file where the staged directory has to be renamed to: the rename fails, and by
    # then the crate has already been moved out of the port's own tree.
    makeFile "not a directory" serde-1.0.0 $vendor
    proc ui_debug {args} {}
} -body {
    set published [rust::publish_crate $vendor [file join $port_a serde-1.0.0]]
    list \
        $published \
        [file isdirectory [file join $port_a serde-1.0.0]] \
        [file exists [file join $port_a serde-1.0.0 lib.rs]] \
        [llength [glob -nocomplain -directory $vendor -types d -- .tmp-*]]
} -cleanup {
    rename ui_debug {}
    file delete -force -- $vendor $port_a
} -result {0 1 1 0}

test vendor-switch-leaves-every-declared-crate-reachable {
    End to end: pristine crates move to the shared tree, a modified one stays private and is
    named in `paths`, and the rendered config.toml gives cargo a route to every crate the port
    declares -- through the shared directory source or through an override.
} -setup {
    set ::rust::pristine_signatures [dict create]
    set rustcache [makeDirectory switch_rustcache]
    set workpath [makeDirectory switch_work]
    set cargo_home [makeDirectory .cargo [makeDirectory .home $workpath]]
    set source_dir [makeDirectory macports $cargo_home]
    foreach name {serde-1.0.0 libc-0.2.0 kqueue-1.0.4} {
        set dir [makeDirectory $name $source_dir]
        makeFile "// crate" lib.rs $dir
        makeFile "\[package\]" Cargo.toml $dir
        makeFile "{\"package\": \"chk-$name\", \"files\": {}}" .cargo-checksum.json $dir
        rust::note_pristine_signature $cargo_home $name
    }
    rust::record_vendor_signatures $cargo_home
    # kqueue stands in for a crate old_macos_compatibility rewrote after extraction.
    set patched [file join $source_dir kqueue-1.0.4 lib.rs]
    set fd [open $patched a]
    puts $fd "// patched"
    close $fd
    file mtime $patched [expr {[clock seconds] + 120}]

    set ::cargo.home $cargo_home
    set ::cargo.crates {serde 1.0.0 a libc 0.2.0 b kqueue 1.0.4 c}
    set ::cargo.crates_github {}
    set ::cargo.vendor_shared yes
    set ::cargo.update no
    set ::configure.rustcache yes
    set ::rustcache_dir $rustcache
    set ::prefix /opt/local
    set ::worksrcpath [makeDirectory src $workpath]
    set ::portdbpath [makeDirectory portdb $workpath]
    set ::wrapper [makeFile "#!/bin/sh\n" ld [makeDirectory compwrap $workpath]]
    set ::switch_options [dict create \
        os.platform darwin \
        macosx_deployment_target 15.0 \
        rust.flags {} \
        triplet.arm64 aarch64-apple-darwin \
        triplet.x86_64 x86_64-apple-darwin \
        triplet.i386 i686-apple-darwin \
        triplet.ppc powerpc-apple-darwin \
        triplet.ppc64 powerpc64-apple-darwin]
    proc option {name} {return [dict get $::switch_options $name]}
    proc tbool {name} {
        upvar #0 $name value
        return [expr {[info exists value] && [string is true -strict $value]}]
    }
    namespace eval compwrap {}
    proc compwrap::wrap_compiler {tag} {return $::wrapper}
    proc ui_debug {args} {}
    proc ui_warn {args} {}
} -body {
    rust::vendor_switch
    set fd [open [file join $cargo_home config.toml] r]
    set text [read $fd]
    close $fd
    list \
        [lsort [lmap p [glob -nocomplain -directory [file join $rustcache vendor] -types d -- *] {file tail $p}]] \
        [lsort [lmap p [glob -nocomplain -directory $source_dir -types d -- *] {file tail $p}]] \
        [expr {[string first "paths = \[\"[file join $source_dir kqueue-1.0.4]\"\]" $text] == 0}] \
        [expr {[string first "directory = \"[file join $rustcache vendor]\"" $text] >= 0}] \
        [expr {[string first [file join $rustcache compwrap] $text] >= 0}]
} -cleanup {
    foreach c {option tbool compwrap::wrap_compiler ui_debug ui_warn} {rename $c {}}
    foreach v {cargo.home cargo.crates cargo.crates_github cargo.vendor_shared cargo.update
               configure.rustcache rustcache_dir prefix worksrcpath portdbpath wrapper
               switch_options} {
        unset -nocomplain ::$v
    }
    set ::rust::pristine_signatures [dict create]
    file delete -force -- $rustcache $workpath
} -result {{libc-0.2.0 serde-1.0.0} kqueue-1.0.4 1 1 1}

set failed $::tcltest::numTests(Failed)
cleanupTests
if {${failed} > 0} {
    exit 1
}
