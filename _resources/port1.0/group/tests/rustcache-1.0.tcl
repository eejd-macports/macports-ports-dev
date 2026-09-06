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

set failed $::tcltest::numTests(Failed)
cleanupTests
if {${failed} > 0} {
    exit 1
}
