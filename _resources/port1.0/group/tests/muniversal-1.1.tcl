#!/usr/bin/env port-tclsh
# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:ft=tcl:et:sw=4:ts=4:sts=4

package require tcltest 2
namespace import tcltest::*
::tcltest::configure {*}$::argv

set testdir [file dirname [file normalize [info script]]]

proc evaluate_supported_arch_forwarding {call_args} {
    set child [interp create]
    try {
        $child eval {
            proc unknown {args} {}
            proc command_string {args} {}
            proc parse_environment {args} {}
            proc get_canonical_archflags {args} {}
            proc universal_setup {args} {}
            namespace eval portconfigure {
                proc choose_supported_archs {args} {
                    set ::forwarded_arch_args $args
                    return {arm64 x86_64}
                }
            }
            namespace eval portpatch {
                proc patch_main {args} {}
            }
            namespace eval portdestroot {
                proc destroot_start {args} {}
                proc destroot_finish {args} {}
            }
        }
        $child eval [list source [file join $::testdir .. muniversal-1.1.tcl]]
        $child eval {
            set os.arch arm
            proc option {name} { return no }
        }
        set result [$child eval [list portconfigure::choose_supported_archs {*}$call_args]]
        list $result [$child eval {set forwarded_arch_args}]
    } finally {
        interp delete $child
    }
}

test muniversal-forwards-one-argument {
    The legacy one-argument base API remains supported.
} -body {
    evaluate_supported_arch_forwarding [list {arm64 x86_64}]
} -result {{arm64 x86_64} {{arm64 x86_64}}}

test muniversal-forwards-three-arguments {
    All arguments from the expanded base API reach the original implementation unchanged.
} -body {
    evaluate_supported_arch_forwarding [list {arm64 x86_64} {arm64 x86_64 i386} yes]
} -result {{arm64 x86_64} {{arm64 x86_64} {arm64 x86_64 i386} yes}}

set failed $::tcltest::numTests(Failed)
cleanupTests
if {${failed} > 0} {
    exit 1
}
