#!/usr/bin/perl
# Build a distributable libtrackingutils.so for the q2ctrl module.
#
# v1.1 materialised one Q2 address with four movz/movk immediates, which baked a
# single controller into the binary. This builds the same logic but reads the
# addresses from literals in the function's own tail, so the installer can drop
# the local controller's address in with a plain byte write. No bit-packing, no
# reassembly, and re-running it after pairing a different controller is one dd.
#
# Three slots, because both hands can be Quest 2. An unset slot is zero, which no
# real controller can match, so a lib with no addresses behaves exactly stock.
#
# Space comes from the function itself. Removing the stock bounds check (v1.1 did
# this too) orphans the out-of-range assert block at 0x20d10, giving 32 bytes that
# hold three 8-byte literals plus the return block, ending exactly where the next
# function begins.
#
# usage: perl build_ltu_q2addr.pl <stock.so> <out.so> [addr ...]

use strict;
use warnings;
use Digest::SHA qw(sha1_hex);

my $STOCK_SHA = '1ee35835de7cba4ad25407bef6612ad21a63b365';

# getControllerModel(ControllerType w0, ControllerAddr x1) @ VA 0x20cd8
my $FN      = 0x1fcd8;                        # file offset of the function
my @SLOT    = (0x1fd10, 0x1fd18, 0x1fd20);    # the three address literals
my $MAXSLOT = scalar @SLOT;

my ($in, $out, @addrs) = @ARGV;
die "usage: $0 <stock.so> <out.so> [addr ...]\n" unless $in && $out;
die "at most $MAXSLOT addresses\n" if @addrs > $MAXSLOT;

my $d = do { local (@ARGV, $/) = $in; <> };
die "input is not the stock libtrackingutils (sha1 " . sha1_hex($d) . ")\n"
    unless sha1_hex($d) eq $STOCK_SHA;

# Make sure we are pointing at the real function before touching anything.
die sprintf("unexpected prologue at 0x%x\n", $FN)
    unless unpack('V', substr($d, $FN, 4)) == 0xa9bf7bfd;   # stp x29,x30,[sp,#-0x10]!
die sprintf("unexpected assert block at 0x%x\n", $FN + 0x38)
    unless unpack('V', substr($d, $FN + 0x38, 4)) == 0xf0ffff42;   # adrp x2, 0xb000

# ldr x8, LIT1 / cmp / b.eq HIT   x3, then fall through to the stock table path.
# Offsets are relative to $FN; the three gaps left at +0x24, +0x28 and +0x34 keep
# the stock adrp/add/ret bytes exactly as they are.
my %word = (
    0x00 => 0x580001c8,   # ldr  x8, LIT1
    0x04 => 0xeb08003f,   # cmp  x1, x8
    0x08 => 0x54000240,   # b.eq HIT
    0x0c => 0x580001a8,   # ldr  x8, LIT2
    0x10 => 0xeb08003f,   # cmp  x1, x8
    0x14 => 0x540001e0,   # b.eq HIT
    0x18 => 0x58000188,   # ldr  x8, LIT3
    0x1c => 0xeb08003f,   # cmp  x1, x8
    0x20 => 0x54000180,   # b.eq HIT

    # The stock table path indexed on w4, which the old prologue set up. That
    # prologue is gone, so read the index from w0 where the caller left it.
    0x2c => 0xb860d900,   # ldr  w0, [x8, w0, sxtw #2]

    # Stock epilogue popped the frame the old prologue pushed. Nothing is pushed.
    0x30 => 0xd503201f,   # nop

    0x50 => 0x52836b20,   # HIT: mov w0, #0x1b59   (model 7001, Jedi LED geometry)
    0x54 => 0xd65f03c0,   #      ret
);
substr($d, $FN + $_, 4) = pack 'V', $word{$_} for keys %word;

# Slots are written high/low so a 64-bit hex literal never goes through hex().
for my $i (0 .. $MAXSLOT - 1) {
    my $a = $addrs[$i];
    my ($hi, $lo) = (0, 0);
    if (defined $a) {
        $a =~ s/^0[xX]//;
        die "address '$a' must be 16 hex digits\n" unless $a =~ /^[0-9a-fA-F]{16}$/;
        ($hi, $lo) = (hex(substr($a, 0, 8)), hex(substr($a, 8, 8)));
    }
    substr($d, $SLOT[$i], 8) = pack 'VV', $lo, $hi;
}

open my $fh, '>:raw', $out or die "$out: $!\n";
print $fh $d;
close $fh;

printf "wrote %s\n  size %d\n  sha1 %s\n", $out, length($d), sha1_hex($d);
printf "  slot %d @ 0x%x = %s\n", $_, $SLOT[$_],
    defined $addrs[$_] ? lc($addrs[$_]) : '(unset)' for 0 .. $MAXSLOT - 1;
