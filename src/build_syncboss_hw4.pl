#!/usr/bin/perl
# Flip the Jedi entry's hardware_type from 2 (LCON) to 4 (JEDI).
#
# The sensors HAL maps hardware_type -> ControllerType through a jump table, and
# ControllerType is what selects the grip/aim offset. Leaving the second entry at
# 2 makes the Q2 report as LCON and inherit the Quest 1's pose offset, which is
# why its angles are wrong.
#
# This was avoided for a long time because the stability matrix blamed it for
# tripling the link churn. That matrix was measured with the second controller
# slot paired-but-absent, so the radio was running a permanent discovery scan the
# whole time. With both controllers actually connected the baseline is 0 resets,
# so the pairing is worth retesting on its own terms.
#
# usage: perl build_syncboss_hw4.pl <two-entry.so> <out.so>

use strict;
use warnings;
use Digest::SHA qw(sha1_hex);

my $IN_SHA  = '19f28f7f314b69eff85b699c8801cb42ae04e65f';   # two-entry, hw_type 2
my $OUT_SHA = '7611d69f15101a06369753d8c8edec8161be59cb';   # same, hw_type 4
my $OFF     = 0x40a04;                                      # entry1 +0x04

my ($in, $out) = @ARGV;
die "usage: $0 <two-entry.so> <out.so>\n" unless $in && $out;

my $d = do { local (@ARGV, $/) = $in; <> };
die "input is not the two-entry libsyncboss (sha1 " . sha1_hex($d) . ")\n"
    unless sha1_hex($d) eq $IN_SHA;

my $was = ord substr($d, $OFF, 1);
die sprintf("expected hardware_type 2 at 0x%x, found %d\n", $OFF, $was) unless $was == 2;
substr($d, $OFF, 1) = chr 4;

open my $fh, '>:raw', $out or die "$out: $!\n";
print $fh $d;
close $fh;

my $got = sha1_hex($d);
printf "wrote %s\n  hardware_type 0x%x: %d -> 4\n  sha1 %s%s\n",
    $out, $OFF, $was, $got,
    $got eq $OUT_SHA ? "  (matches the known hw4 build)" : "  (UNEXPECTED, wanted $OUT_SHA)";
